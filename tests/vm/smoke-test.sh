#!/usr/bin/env bash
#
# Tier 3 smoke test: boot a throwaway Debian Trixie VM and run the installer
# inside it, then assert that openmediavault ends up installed.
#
# HOST SAFETY:
#   - The installer is NEVER run on this host. It is embedded into the guest via
#     cloud-init and executed only inside the ephemeral VM.
#   - The VM disk is a qcow2 *overlay* on top of an untouched, read-only base
#     image, so nothing the guest does can affect the host or the base image.
#   - Networking is isolated NAT (no host LAN bridging): qemu backend uses
#     user-mode SLIRP; libvirt backend uses libvirt's default NAT network
#     (virbr0, 192.168.122.0/24) — the same setup ordinary libvirt VMs use.
#   - The installer runs with "-n -r" (skip host network teardown + reboot) so
#     the guest stays reachable for apt and the run terminates cleanly.
#
# Backends:
#   qemu    (default) raw qemu-system-x86_64.
#   libvirt virt-install + virsh; manages the domain lifecycle. Defaults to the
#           qemu:///system connection + default NAT network (override --connect).
#           Run with sudo. libvirt runs qemu as the 'libvirt-qemu' user, so the
#           throwaway run dir and disk are made accessible to it (ephemeral,
#           isolated files).
#
# Common requirements: qemu-system-x86_64, KVM (/dev/kvm), wget or curl, and a
# seed-image tool (cloud-localds | genisoimage | xorriso | mkisofs).
#
# Usage: tests/vm/smoke-test.sh [--backend qemu|libvirt] [--connect URI]
#                               [--keep] [--timeout SECONDS] [--mem MB]
#                               [--image-url URL]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
INSTALL="${REPO}/install"
ART="${HERE}/.artifacts"

BACKEND=qemu
LIBVIRT_URI="qemu:///system"
KEEP=0
TCG=0
TIMEOUT=1800
MEM=2048
CPUS=2
IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
DOM=""
QEMU_PID=""
GRACE=120

usage() { sed -n '2,30p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="$2"; shift ;;
    --connect) LIBVIRT_URI="$2"; shift ;;
    --keep) KEEP=1 ;;
    --tcg) TCG=1 ;;
    --timeout) TIMEOUT="$2"; shift ;;
    --mem) MEM="$2"; shift ;;
    --image-url) IMAGE_URL="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "ERROR: $*" >&2; exit 1; }

case "${BACKEND}" in qemu|libvirt) ;; *) die "--backend must be qemu or libvirt" ;; esac

[ -f "${INSTALL}" ] || die "install script not found at ${INSTALL}"
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed"
if [ "${TCG}" -eq 0 ] && ! { [ -r /dev/kvm ] && [ -w /dev/kvm ]; }; then
  die "/dev/kvm not available/writable (KVM required unless --tcg; run as root or join the 'kvm' group)"
fi

# pick a tool to build the cloud-init seed image (qemu backend only)
make_seed() { # <user-data> <meta-data> <out.iso>
  if command -v cloud-localds >/dev/null; then
    cloud-localds "$3" "$1" "$2"
  elif command -v genisoimage >/dev/null; then
    genisoimage -output "$3" -volid cidata -joliet -rock "$1" "$2" >/dev/null 2>&1
  elif command -v xorriso >/dev/null; then
    xorriso -as mkisofs -output "$3" -volid cidata -joliet -rock "$1" "$2" >/dev/null 2>&1
  elif command -v mkisofs >/dev/null; then
    mkisofs -output "$3" -volid cidata -joliet -rock "$1" "$2" >/dev/null 2>&1
  else
    die "qemu backend needs cloud-localds, genisoimage, xorriso, or mkisofs to build the seed"
  fi
}

if [ "${BACKEND}" = libvirt ]; then
  command -v virt-install >/dev/null || die "virt-install not installed (libvirt backend)"
  command -v virsh >/dev/null || die "virsh not installed (libvirt backend)"
fi

mkdir -p "${ART}"
BASE="${ART}/$(basename "${IMAGE_URL}")"
if [ ! -f "${BASE}" ]; then
  echo "==> downloading base image: ${IMAGE_URL}"
  if command -v wget >/dev/null; then wget -O "${BASE}.part" "${IMAGE_URL}"
  else curl -fSL -o "${BASE}.part" "${IMAGE_URL}"; fi
  mv "${BASE}.part" "${BASE}"
fi

WORK="$(mktemp -d "${ART}/run.XXXXXX")"
OVERLAY="${WORK}/disk.qcow2"
SEED="${WORK}/seed.iso"
SERIAL="${WORK}/serial.log"

# shellcheck disable=SC2317  # invoked via EXIT trap
cleanup() {
  if [ -n "${QEMU_PID}" ]; then
    kill "${QEMU_PID}" 2>/dev/null || true
  fi
  if [ "${BACKEND}" = libvirt ] && [ -n "${DOM}" ]; then
    virsh -c "${LIBVIRT_URI}" destroy "${DOM}" >/dev/null 2>&1 || true
    virsh -c "${LIBVIRT_URI}" undefine "${DOM}" >/dev/null 2>&1 || true
  fi
  if [ "${KEEP}" -eq 1 ]; then
    echo "==> artifacts kept in ${WORK}"
  else
    rm -rf "${WORK}"
  fi
}
trap cleanup EXIT

echo "==> creating throwaway overlay disk (base image stays read-only)"
qemu-img create -f qcow2 -F qcow2 -b "${BASE}" "${OVERLAY}" >/dev/null  # inherit backing size

# cloud-init: embed the installer and run it inside the guest, echoing
# result markers to the serial console for the host to parse.
INSTALL_B64="$(base64 -w0 "${INSTALL}")"
cat > "${WORK}/meta-data" <<EOF
instance-id: omv-smoke-$$
local-hostname: omv-smoke
EOF
cat > "${WORK}/user-data" <<EOF
#cloud-config
write_files:
  - path: /root/install
    encoding: b64
    permissions: '0755'
    content: ${INSTALL_B64}
runcmd:
  # Use a public resolver directly: QEMU user-mode SLIRP forwards DNS to the
  # host's 127.0.0.53 stub, which doesn't work, so resolution fails. Outbound
  # NAT to real IPs is fine, so querying 1.1.1.1/8.8.8.8 directly works. We run
  # the installer with -n, so it never rewrites resolv.conf and this sticks.
  - bash -c 'exec > /dev/console 2>&1; rm -f /etc/resolv.conf; printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf; echo "SMOKE_BEGIN"; bash /root/install -n -r > /var/log/omv-install.log 2>&1; echo "SMOKE_INSTALL_RC=\$?"; dpkg-query -s openmediavault 2>/dev/null | grep -q "install ok installed" && echo "OMV_PKG_STATUS=ii" || echo "OMV_PKG_STATUS=absent"; dpkg-query -s openmediavault-omvextrasorg 2>/dev/null | grep -q "install ok installed" && echo "OMVEXTRAS_PKG_STATUS=ii" || echo "OMVEXTRAS_PKG_STATUS=absent"; echo "SMOKE_END"; sync; systemctl --no-block poweroff || poweroff -f'
power_state:
  mode: poweroff
  timeout: 60
  condition: true
EOF

# Build the NoCloud seed once; both backends attach it as a 'cidata' volume.
echo "==> building cloud-init seed"
make_seed "${WORK}/user-data" "${WORK}/meta-data" "${SEED}"

# Wait for the guest to stop. The guest powers itself off after SMOKE_END, but
# cloud-init can crash once the installer has restarted systemd units, leaving
# the VM up. So once SMOKE_END is on the serial console, give the guest
# ${GRACE}s to power off and then stop it ourselves; the result comes from the
# markers either way. Sets ${rc} (0 ok, 124 timeout before SMOKE_END).
wait_guest() { # <is-running cmd...> -- <stop cmd...>
  local running=() stop=()
  while [ "$1" != "--" ]; do running+=("$1"); shift; done
  shift
  stop=("$@")
  local deadline end_at=0 now
  deadline=$(( $(date +%s) + TIMEOUT ))
  rc=0
  while "${running[@]}"; do
    now=$(date +%s)
    if [ "${end_at}" -eq 0 ] && grep -aq 'SMOKE_END' "${SERIAL}" 2>/dev/null; then
      echo "==> SMOKE_END seen; waiting up to ${GRACE}s for guest power off"
      end_at=$(( now + GRACE ))
    fi
    if [ "${end_at}" -ne 0 ] && [ "${now}" -ge "${end_at}" ]; then
      echo "==> guest did not power off after SMOKE_END; stopping it"
      "${stop[@]}"
      break
    fi
    if [ "${now}" -ge "${deadline}" ]; then
      "${stop[@]}"
      [ "${end_at}" -eq 0 ] && rc=124
      break
    fi
    sleep 5
  done
}

# Launch the guest. Each backend sets ${rc} (0 ok, 124 timeout) and writes the
# guest serial console to ${SERIAL}.
run_qemu() {
  local accel
  if [ "${TCG}" -eq 1 ]; then accel=(-accel tcg -cpu max); else accel=(-enable-kvm -cpu host); fi
  echo "==> [qemu] booting guest (accel: ${accel[*]}, timeout ${TIMEOUT}s, ${MEM}MB, ${CPUS} vCPU)"
  qemu-system-x86_64 \
    "${accel[@]}" -m "${MEM}" -smp "${CPUS}" \
    -display none -monitor none -serial "file:${SERIAL}" \
    -drive "file=${OVERLAY},if=virtio,format=qcow2" \
    -drive "file=${SEED},if=virtio,format=raw,readonly=on" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -no-reboot &
  QEMU_PID=$!
  wait_guest qemu_running -- qemu_stop
  wait "${QEMU_PID}" 2>/dev/null || true
  QEMU_PID=""
}

run_libvirt() {
  DOM="omv-smoke-$$"
  # libvirt runs qemu as the unprivileged 'libvirt-qemu' user, which must be
  # able to traverse the run dir and open the (throwaway) disk + backing image.
  # The mktemp dir is 0700 and qemu-img creates the overlay 0644, so widen them.
  # Safe: ephemeral files for an isolated, single-boot VM.
  chmod 0755 "${WORK}"
  chmod 0644 "${BASE}" "${SEED}" 2>/dev/null || true
  chmod 0666 "${OVERLAY}"
  echo "==> [libvirt] defining and starting domain ${DOM} on ${LIBVIRT_URI}"
  # KVM + host CPU passthrough by default (Trixie needs the x86-64-v2 baseline
  # the default emulated CPU lacks); --tcg falls back to software emulation with
  # a v2-capable model for hosts where KVM/nested boot fails.
  local cpuopt
  if [ "${TCG}" -eq 1 ]; then cpuopt=(--virt-type qemu --cpu Nehalem); else cpuopt=(--virt-type kvm --cpu host-passthrough); fi
  # Attach the seed ISO as a read-only virtio disk (NoCloud 'cidata' volume).
  # virtio block devices are reliably probed by cloud-init's ds-identify; an IDE
  # cdrom is not always detected, leaving cloud-init disabled for the boot.
  virt-install --connect "${LIBVIRT_URI}" \
    --name "${DOM}" --memory "${MEM}" --vcpus "${CPUS}" \
    "${cpuopt[@]}" \
    --boot uefi \
    --import \
    --disk "path=${OVERLAY},format=qcow2,bus=virtio" \
    --disk "path=${SEED},format=raw,bus=virtio,readonly=on" \
    --network network=default,model=virtio \
    --osinfo "detect=on,require=off" \
    --graphics none --noautoconsole \
    --serial "file,path=${SERIAL}" >/dev/null

  echo "==> [libvirt] waiting for guest to power off (timeout ${TIMEOUT}s)"
  wait_guest dom_running -- dom_destroy
}

# shellcheck disable=SC2317  # invoked via wait_guest
qemu_running() { kill -0 "${QEMU_PID}" 2>/dev/null; }
# shellcheck disable=SC2317  # invoked via wait_guest
qemu_stop() { kill "${QEMU_PID}" 2>/dev/null || true; }
# shellcheck disable=SC2317  # invoked via wait_guest
dom_running() { virsh -c "${LIBVIRT_URI}" domstate "${DOM}" 2>/dev/null | grep -q running; }
# shellcheck disable=SC2317  # invoked via wait_guest
dom_destroy() { virsh -c "${LIBVIRT_URI}" destroy "${DOM}" >/dev/null 2>&1 || true; }

echo "==> installer runs INSIDE the VM only (backend: ${BACKEND})"
echo "==> guest serial log (follow with: tail -f): ${SERIAL}"
if [ "${BACKEND}" = libvirt ]; then run_libvirt; else run_qemu; fi

# Make the serial log readable without root (it is created 0600 by qemu/libvirt)
# so it can be inspected after a --keep run on a headless host.
chmod 0644 "${SERIAL}" 2>/dev/null || true

echo "==> guest finished (rc=${rc}); parsing serial log"
echo "---------------- serial markers ----------------"
grep -E 'SMOKE_BEGIN|SMOKE_INSTALL_RC|OMV_PKG_STATUS|OMVEXTRAS_PKG_STATUS|SMOKE_END' "${SERIAL}" || echo "(no SMOKE_* markers found — cloud-init runcmd may not have run)"
echo "------------------------------------------------"

fail() { # print serial tail to aid headless debugging, then exit 1
  echo "FAIL: $*"
  echo "---------------- last 40 serial lines ----------------"
  tail -n 40 "${SERIAL}" 2>/dev/null | tr -d '\r' || true
  echo "------------------------------------------------------"
  echo "full serial log: ${SERIAL}"
  echo "(guest install log is /var/log/omv-install.log inside the VM disk)"
  exit 1
}

if [ "${rc}" -eq 124 ]; then
  fail "timed out after ${TIMEOUT}s (try a larger --timeout)"
fi

omv_status="$(grep -m1 'OMV_PKG_STATUS=' "${SERIAL}" | sed 's/.*OMV_PKG_STATUS=//' | tr -d '\r ' || true)"
if [ "${omv_status}" = "ii" ]; then
  echo "PASS: openmediavault is installed (status=${omv_status})"
  exit 0
fi

fail "openmediavault not installed (status='${omv_status:-unknown}')"

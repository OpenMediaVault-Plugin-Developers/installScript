#!/bin/bash
#
# shellcheck disable=SC1090,SC1091,SC1117,SC2016,SC2046,SC2086
#
# Copyright (c) 2015-2020 OpenMediaVault Plugin Developers
# Copyright (c) 2017-2020 Armbian Developers
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# Ideas/code used from:
# https://github.com/armbian/config/blob/master/debian-software
# https://forum.openmediavault.org/index.php/Thread/25062-Install-OMV5-on-Debian-10-Buster/

if [[ $(id -u) -ne 0 ]]; then
 echo "This script must be executed as root or using sudo."
 exit 99
fi

declare -l codename
declare -l omvCodename
declare -l omvInstall=""
declare -l omvextrasInstall=""
declare -i skipFlash=0
declare -i version

cpuFreqDef="/etc/default/cpufrequtils"
defaultGovSearch="^CONFIG_CPU_FREQ_DEFAULT_GOV_"
ioniceCron="/etc/cron.d/make_nas_processes_faster"
ioniceScript="/usr/sbin/omv-ionice"
keyserver="hkp://keyserver.ubuntu.com:80"
omvKey="/etc/apt/trusted.gpg.d/openmediavault-archive-keyring.asc"
omvRepo="http://packages.openmediavault.org/public"
omvSources="/etc/apt/sources.list.d/openmediavault.list"
smbOptions="min receivefile size = 16384\nwrite cache size = 524288\ngetwd cache = yes\nsocket options = TCP_NODELAY IPTOS_LOWDELAY"
url="https://github.com/OpenMediaVault-Plugin-Developers/packages/raw/master/"

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export LANG=C.UTF-8

if [ -f /etc/armbian-release ]; then
  . /etc/armbian-release
fi

while getopts "fh" opt; do
  echo "option ${opt}"
  case "${opt}" in
    f)
      skipFlash=1
      ;;
    h)
      echo "Use the following flags:"
      echo "  -f"
      echo "    to skip the installation of the flashmemory plugin"
      echo ""
      echo "Examples:"
      echo "  install"
      echo "  install -f"
      exit 100
      ;;
    \?)
      echo "Invalid option: -${OPTARG}"
      ;;
  esac
done

# Fix permissions on / if wrong
echo "Current / permissions = $(stat -c %a /)"
chmod g-w,o-w /
echo "New / permissions = $(stat -c %a /)"

echo "Updating repos before installing..."
apt-get update

if [ ! -f "/usr/bin/lsb_release" ]; then
  echo "Installing lsb_release..."
  apt-get --yes --no-install-recommends install lsb-release
fi

arch="$(dpkg --print-architecture)"
codename="$(lsb_release --codename --short)"
distributor="$(lsb_release --id --short)"

case ${codename} in
  stretch)
    confCmd="omv-mkconf"
    ntp="ntp"
    omvCodename="arrakis"
    phpfpm="php-fpm"
    version=4
    ;;
  buster|eoan)
    confCmd="omv-salt deploy run"
    ntp="chrony"
    omvCodename="usul"
    phpfpm="phpfpm"
    version=5
    ;;
  *)
    echo "Unsupported version.  Exiting..."
    exit 1
  ;;
esac
echo "${omvCodename} :: ${version}"

hostname=$(</etc/hostname)
tz=$(</etc/timezone)

# Add Debian signing keys to raspbian to prevent apt-get update failures
# when OMV adds security and/or backports repos
if [[ "${distributor}" == "Raspbian" ]]; then
  echo "Adding Debian signing keys..."
  for key in AA8E81B4331F7F50 112695A0E562B32A 04EE7237B7D453EC 648ACFD622F3D138; do
    apt-key adv --no-tty --keyserver ${keyserver} --recv-keys "${key}"
  done
fi

echo "Install prerequisites..."
apt-get --yes --no-install-recommends install dirmngr gnupg

# install openmediavault if not installed already
omvInstall=$(dpkg -l | awk '$2 == "openmediavault" { print $1 }')
if [[ ! "${omvInstall}" == "ii" ]]; then
  echo "Installing openmediavault required packages..."
  if ! apt-get --yes --no-install-recommends install postfix; then
    echo "failed installing postfix"
    exit 2
  fi

  echo "Adding openmediavault repo and key..."
  echo "deb ${omvRepo} ${omvCodename} main" > ${omvSources}
  wget -O "${omvKey}" ${omvRepo}/archive.key
  apt-key add "${omvKey}"

  echo "Updating repos..."
  if ! apt-get update; then
    echo "failed to update apt repos."
    exit 2
  fi

  echo "Install openmediavault-keyring..."
  if ! apt-get --yes install openmediavault-keyring; then
    echo "failed to install openmediavault-keyring package."
    exit 2
  fi

  echo "Installing openmediavault..."
  aptFlags="--yes --auto-remove --show-upgraded --allow-downgrades --allow-change-held-packages --no-install-recommends"
  cmd="apt-get ${aptFlags} install openmediavault"
  if ! ${cmd}; then
    echo "failed to install openmediavault package."
    exit 2
  fi

  if [ ${version} -gt 4 ]; then
    omv-confdbadm populate
  else
    omv-initsystem
    omv-mkconf interfaces
    omv-mkconf issue
  fi
fi

# check if openmediavault is install properly
omvInstall=$(dpkg -l | awk '$2 == "openmediavault" { print $1 }')
if [[ ! "${omvInstall}" == "ii" ]]; then
  echo "openmediavault package failed to install or is in a bad state."
  exit 3
fi

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

# remove backports from sources.list to avoid duplicate sources warning
sed -i "/\(stretch\|buster\)-backports/d" /etc/apt/sources.list

if [ "${codename}" = "eoan" ]; then
  omv_set_default "OMV_APT_USE_KERNEL_BACKPORTS" false true
fi

# install omv-extras
echo "Downloading omv-extras.org plugin for openmediavault ${version}.x ..."
file="openmediavault-omvextrasorg_latest_all${version}.deb"

if [ -f "${file}" ]; then
  rm ${file}
fi
wget ${url}/${file}
if [ -f "${file}" ]; then
  if ! dpkg --install ${file}; then
    echo "Installing other dependencies ..."
    apt-get --yes --fix-broken install
    omvextrasInstall=$(dpkg -l | awk '$2 == "openmediavault-omvextrasorg" { print $1 }')
    if [[ ! "${omvextrasInstall}" == "ii" ]]; then
      echo "omv-extras failed to install correctly.  Trying to fix with ${confCmd} ..."
      if ${confCmd} omvextras; then
        echo "Trying to fix apt ..."
        apt-get --yes --fix-broken install
      else
        echo "${confCmd} failed and openmediavault-omvextrasorg is in a bad state."
        exit 3
      fi
    fi
    omvextrasInstall=$(dpkg -l | awk '$2 == "openmediavault-omvextrasorg" { print $1 }')
    if [[ ! "${omvextrasInstall}" == "ii" ]]; then
      echo "openmediavault-omvextrasorg package failed to install or is in a bad state."
      exit 3
    fi
  fi

  echo "Updating repos ..."
  apt-get update
else
  echo "There was a problem downloading the package."
fi

# disable armbian log services if found
for service in log2ram armbian-ramlog; do
  if systemctl list-units --full -all | grep ${service}; then
    systemctl stop ${service}
    systemctl disable ${service}
    rm -f /etc/cron.daily/${service}*
  fi
done

# install flashmemory plugin unless disabled
if [ ${skipFlash} -eq 1 ]; then
  echo "Skipping installation of the flashmemory plugin."
else
  echo "Install folder2ram..."
  if apt-get --yes --fix-missing --no-install-recommends install folder2ram; then
    echo "Installed folder2ram."
  else
    echo "Failed to install folder2ram."
  fi
  echo "Install flashmemory plugin..."
  if apt-get --yes install openmediavault-flashmemory; then
    echo "Installed flashmemory plugin."
  else
    echo "Failed to install flashmemory plugin."
    ${confCmd} flashmemory
    apt-get --yes --fix-broken install
  fi
fi

# change default OMV settings
xmlstarlet ed -L -u "/config/services/smb/extraoptions" -v "$(echo -e "${smbOptions}")" ${OMV_CONFIG_FILE}
xmlstarlet ed -L -u "/config/services/ssh/enable" -v "1" ${OMV_CONFIG_FILE}
xmlstarlet ed -L -u "/config/services/ssh/permitrootlogin" -v "1" ${OMV_CONFIG_FILE}
xmlstarlet ed -L -u "/config/system/time/ntp/enable" -v "1" ${OMV_CONFIG_FILE}
xmlstarlet ed -L -u "/config/system/time/timezone" -v "${tz}" ${OMV_CONFIG_FILE}
xmlstarlet ed -L -u "/config/system/network/dns/hostname" -v "${hostname}" ${OMV_CONFIG_FILE}

# disable monitoring and apply changes
/usr/sbin/omv-rpc -u admin "perfstats" "set" '{"enable":false}'
/usr/sbin/omv-rpc -u admin "config" "applyChanges" '{ "modules": ["monit","rrdcached","collectd"],"force": true }'

# set min and max frequency for RPi boards
if [[ "${distributor}" == "Raspbian" ]]; then
  MIN_SPEED="$(</sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq)"
  MAX_SPEED="$(</sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)"
  # Determine if RPi4 (for future use)
  if [[ $(awk '$1 == "Revision" { print $3 }' /proc/cpuinfo) =~ [a-c]03111 ]]; then
    BOARD="rpi4"
  fi
  cat << EOF > ${cpuFreqDef}
GOVERNOR="ondemand"
MIN_SPEED="${MIN_SPEED}"
MAX_SPEED="${MAX_SPEED}"
EOF
fi

if [ -f "${cpuFreqDef}" ]; then
  . ${cpuFreqDef}
else
  # set cpufreq settings if no defaults
  if [ -f "/proc/config.gz" ]; then
    defaultGov="$(zgrep "${defaultGovSearch}" /proc/config.gz | sed -e "s/${defaultGovSearch}\(.*\)=y/\1/")"
  elif [ -f "/boot/config-$(uname -r)" ]; then
    defaultGov="$(grep "${defaultGovSearch}" /boot/config-$(uname -r) | sed -e "s/${defaultGovSearch}\(.*\)=y/\1/")"
  fi
  if [ -z "${DEFAULT_GOV}" ]; then
    defaultGov="ondemand"
  fi
  GOVERNOR=${defaultGov,,}
  MIN_SPEED="0"
  MAX_SPEED="0"
fi

# set defaults in /etc/default/openmediavault
omv_set_default "OMV_CPUFREQUTILS_GOVERNOR" "${GOVERNOR}"
omv_set_default "OMV_CPUFREQUTILS_MINSPEED" "${MIN_SPEED}"
omv_set_default "OMV_CPUFREQUTILS_MAXSPEED" "${MAX_SPEED}"

if [ ${version} -gt 4 ]; then
  # update pillar default list - /srv/pillar/omv/default.sls
  omv-salt stage run prepare
fi

# update config files
for service in nginx ${phpfpm} samba flashmemory ssh ${ntp} timezone monit rrdcached collectd cpufrequtils ; do
  ${confCmd} ${service}
done

if [[ "${arch}" == "amd64" ]] || [[ "${arch}" == "i386" ]]; then
  # skip ionice on x86 boards
  echo "Done."
  exit 0
fi

# Add a cron job to make NAS processes more snappy and silence rsyslog
cat << EOF > /etc/rsyslog.d/omv-armbian.conf
:msg, contains, "omv-ionice" ~
:msg, contains, "action " ~
:msg, contains, "netsnmp_assert" ~
:msg, contains, "Failed to initiate sched scan" ~
EOF
systemctl restart rsyslog

# add taskset to ionice cronjob for biglittle boards
case ${BOARD} in
  odroidxu4|bananapim3|nanopifire3|nanopct3plus|nanopim3)
    taskset='; taskset -c -p 4-7 ${srv}'
    ;;
  *rk3399*|*edge*|nanopct4|nanopim4|nanopineo4|renegade-elite|rockpi-4*|rockpro64)
    taskset='; taskset -c -p 4-5 ${srv}'
    ;;
  odroidn2)
    taskset='; taskset -c -p 2-5 ${srv}'
    ;;
esac

# create ionice script
cat << EOF > ${ioniceScript}
#!/bin/sh

for srv in \$(pgrep "ftpd|nfsiod|smbd"); do
  ionice -c1 -p \${srv} ${taskset};
done
EOF
chmod 755 ${ioniceScript}

# create ionice cronjob
cat << EOF > ${ioniceCron}
* * * * * root ${ioniceScript} >/dev/null 2>&1
EOF
chmod 600 ${ioniceCron}

if getent passwd pi > /dev/null; then
  echo "Adding pi user to ssh group ..."
  usermod -a -G ssh pi
fi

# remove networkmanager and dhcpcd5 then configure networkd
if [ ${version} -gt 4 ]; then
  nic="eth0"
  if grep -qw "${nic}" /proc/net/dev; then
    echo "Removing network-manager and dhcpcd5 ..."
    apt-get -y --autoremove purge network-manager dhcpcd5

    echo "Enable and start systemd-resolved ..."
    systemctl enable systemd-resolved
    systemctl start systemd-resolved
    rm /etc/resolv.conf
    ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf

    echo "Configure ${nic} to use networkd ..."
    mkdir -p /etc/systemd/network
    echo -e "[Match]\nName=${nic}\n\n[Network]\nDHCP=yes" > /etc/systemd/network/openmediavault-${nic,,}.network

    echo "Enable networkd ..."
    systemctl enable systemd-networkd

    echo "It is recommended to reboot and then setup the network adapter in the openmediavault web interface."
  fi
fi

exit 0

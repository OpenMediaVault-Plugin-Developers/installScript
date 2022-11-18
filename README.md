### installScript
- Please use a new SD card if installing on an arm/sbc device and flash it with the latest Debian OS Lite (without desktop environment) or Server image available for your SBC.
- This script will install openmediavault, omv-extras, and flashmemory. If you already have openmediavault installed don't worry, your openmediavault will be preserved, only the not installed will be added to the system.
- Installing OMV with a desktop environment is NOT supported.  Please read the forum for the many reasons why.
- This script may alter previous network setups.  This has a greater chance of breaking wifi setup.  Please read the install manual for more help - https://wiki.omv-extras.org/

### Notes
- This script will always install
  - OMV 5.x on Debian 10 (Buster)
  - OMV 6.x on Debian 11 (Bullseye)

### Installation 
To install OMV, OMV-Extras and Flashmemory copy and paste this line in the Terminal and press Enter. The installation will take some time, so enjoy the text flying on the screen. 

***The installation process demands sudo utilization.***

To download and execute the script you can use either *wget* or *curl*, feel free to use what you prefer!

*wget script*
####  
```bash
sudo wget -O - https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install | sudo bash
```

*curl script*
```bash
sudo curl -sSL https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install | sudo bash
```
### To skip network setup
If you don't wanna use the network setup steps of the script, please use copy and paste the followings lines to the terminal. 
```bash
wget https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install
chmod +x install
sudo ./install -n
```

### A detailed guide is available for this script as well
openmediavault is primarily designed to be used in home environments or small home offices, but is not limited to those scenarios. It is a simple and easy to use out-of-the-box solution that everyone can install and administer without needing expert level knowledge of Networking and Storage Systems.

For the OMV-Extras documentation, visit https://wiki.omv-extras.org/

For the new user guide, visit https://wiki.omv-extras.org/doku.php?id=omv6:new_user_guide
 
### Get help for this script in the forum
If you got stuck in any part of this script the openmediavault forum will be the place to find a solution https://forum.openmediavault.org/


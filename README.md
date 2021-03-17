### installScript
- please use a new SD card if installing on an arm/sbc device.
- will install openmediavault, omv-extras, and flashmemory

### install the script's prerequisites
#### apt-get install wget sudo

### download script and execute
- the wget option -O needs to be a capital letter 'O'
- the second wget '-' has a space on both sides
#### sudo wget -O - https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install | sudo bash
#### -OR-
#### sudo curl -sSL https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install | sudo bash

### a detailed guide is available for this script as well
https://openmediavault.readthedocs.io/en/5.x/new_user_guide/newuserguide.html

### get help for this script in the forum
https://forum.openmediavault.org/

### to skip network setup done by the script
- wget https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install
- chmod +x install
- sudo ./install -n

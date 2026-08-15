#!/bin/bash

echo "Starting..."

export DEBIAN_FRONTEND=noninteractive

# download tools:
sudo apt update
sudo apt install -y build-essential libncurses-dev bison flex libssl-dev libelf-dev bc unzip

# download kernel
wget "https://rwth-aachen.sciebo.de/s/MDm6C9fdz7m4nDi/download" -O custom_kernel.tar.gz

# unizip all and also rename
mv custom_kernel.tar.gz custom_kernel.zip
unzip custom_kernel.zip
mv "Natalia - SS2026" Natalia_SS2026
cd Natalia_SS2026

unzip Linux-6-16-Tiers.zip
cd Linux-6-16-Tiers

tar -xvf linux-6.16.1.tar.gz
cd linux-6.16.1

# copy configuration
cp /boot/config-$(uname -r) .config
make olddefconfig

# disable use of key
scripts/config --disable SYSTEM_TRUSTED_KEYS
scripts/config --disable SYSTEM_REVOCATION_KEYS

# compile kernel
make -j$(nproc)

# install kernel
sudo make modules_install
sudo make install

echo "Finished! Update GRUB and reboot"

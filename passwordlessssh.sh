#!/bin/bash
# SSH Remote Host Auto Login Script
# Author: Daniel Gibbs
# Website: http://danielgibbs.co.uk
# Version: 100914
clear
echo "================================="
echo "SSH Auto Login"
echo "================================="
echo ""
echo "Setup SSH access to a remote host without password being required?"
while true; do
        read -p "Continue? [y/N]" yn
        case $yn in
        [Yy]* ) break;;
        [Nn]* ) echo Exiting; return 1;;
        * ) echo "Please answer yes or no.";;
esac
done
echo ""
read -p "Enter the remote host hostname/ip: " remotehost
echo ""
read -p "Enter the remote host username: " user
echo ""
echo "Generating key for ${HOSTNAME}"
echo "================================="
sleep 1
ssh-keygen
echo ""
echo "Copying Key to ${remotehost}"
echo "================================="
sleep 1
ssh-copy-id -i ~/.ssh/id_rsa.pub ${user}@${remotehost}
sleep 1
exit

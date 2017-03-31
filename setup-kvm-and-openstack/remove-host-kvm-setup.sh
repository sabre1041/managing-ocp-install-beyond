#!/bin/bash


virsh destroy rhelosp
virsh undefine rhelosp
rm -f /var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2
sed -i /192.168.122.10/d ~/.ssh/known_hosts

# Remove SSH keys
if [ -f ~/.ssh/host-kvm-setup ]
then
  rm -rf ~/.ssh/host-kvm-setup*
fi

# Remove SSH config if it exists
if [ -f ~/.ssh/config ]
then
  cp ~/.ssh/config{,.orig}
  rm -rf ~/.ssh/config
fi

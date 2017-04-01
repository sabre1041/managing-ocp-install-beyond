#!/bin/bash


virsh destroy rhelosp
virsh undefine rhelosp
virsh net-destroy L104353
virsh net-undefine L104353
rm -f /var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2

# There shouldn't be any entries for this VM, but just in case remove it
if grep 192.168.122.10 ~/.ssh/known_hosts
then
  sed -i /192.168.122.10/d ~/.ssh/known_hosts
fi

# Remove SSH keys
if [ -f ~/.ssh/host-kvm-setup ]
then
  rm -rf ~/.ssh/host-kvm-setup*
fi


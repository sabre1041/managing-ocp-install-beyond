#!/bin/bash

virsh destroy rhelosp
virsh undefine rhelosp
virsh net-destroy L104353
virsh net-undefine L104353
for network in admin osp; do
  virsh net-destroy L104353-${network}
  virsh net-undefine L104353-${network}
done
rm -f /var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2

# Remove the dnsmasq configuration and reload NetworkManager
rm -f /etc/NetworkManager/conf.d/L104353.conf /etc/NetworkManager/dnsmasq.d/L104353*.conf
systemctl restart NetworkManager

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


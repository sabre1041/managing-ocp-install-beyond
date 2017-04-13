#!/bin/bash

source group_vars_all

for network in admin rhosp; do
  if virsh net-list | grep -q ${LAB_NAME}-${network}
  then
    virsh net-destroy ${LAB_NAME}-${network}
    virsh net-undefine ${LAB_NAME}-${network}
  fi
done

# Remove the dnsmasq configuration and reload NetworkManager
rm -fv /etc/NetworkManager/conf.d/${LAB_NAME}.conf /etc/NetworkManager/dnsmasq.d/${LAB_NAME}*.conf
systemctl restart NetworkManager

# Remove SSH keys
if [ -f "${SSH_KEY_FILENAME}" ]
then
  rm -rf ${SSH_KEY_FILENAME}*
fi

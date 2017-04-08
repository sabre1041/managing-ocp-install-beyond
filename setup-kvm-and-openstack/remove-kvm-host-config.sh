#!/bin/bash

source group_vars_all

virsh net-destroy ${LAB_NAME}
virsh net-undefine ${LAB_NAME}
for network in admin rhosp; do
  virsh net-destroy ${LAB_NAME}-${network}
  virsh net-undefine ${LAB_NAME}-${network}
done


# Remove the dnsmasq configuration and reload NetworkManager
rm -f /etc/NetworkManager/conf.d/${LAB_NAME}.conf /etc/NetworkManager/dnsmasq.d/${LAB_NAME}*.conf
systemctl restart NetworkManager

# Remove SSH keys
if [ -f "${SSH_KEY_FILENAME}" ]
then
  rm -rf ${SSH_KEY_FILENAME}*
fi

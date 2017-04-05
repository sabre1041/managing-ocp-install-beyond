#!/bin/bash

source group_vars_all

cmd wget --continue --directory-prefix=/tmp/ ${TOWER_IMAGE_URL}
cmd cp -fv /tmp/${TOWER_IMAGE_NAME} /var/lib/libvirt/images/${TOWER_IMAGE_NAME}

# Bring up VM if it doesn't exist
if ! virsh list | grep -q ${TOWER_VM_NAME}
then
  cmd virt-install --ram 4096 --vcpus 2 --os-variant rhel7 \
    --disk path=/var/lib/libvirt/images/${TOWER_IMAGE_NAME},device=disk,bus=virtio,format=qcow2 \
    --import --noautoconsole --vnc \
    --network network:${LAB_NAME}-admin \
    --network network:${LAB_NAME}-osp \
    --name ${TOWER_VM_NAME}
fi

echo -n "Waiting for ${TOWER_VM_NAME} VM to come online"
counter=0
while :
do
  counter=$(( $counter + 1 ))
  sleep 1
  TOWER_VM_IP=$(virsh domifaddr ${TOWER_VM_NAME} | grep 192.168.144 | awk '{print $4}'| cut -d/ -f1)
  if [ ! -z ${TOWER_VM_IP} ]
  then
    break
  fi
  if [ $counter -gt $TIMEOUT ]
  then
    echo ERROR: something went wrong - check console
    exit 1
  elif [ $counter -eq $TIMEOUT_WARN ]
  then
    echo -n "WARN: this is taking longer than expected"
  fi
  echo -n "."
done
echo ""

echo -n "Waiting for ${TOWER_VM_NAME} sshd to be available"
counter=0
while :
do
  counter=$(( $counter + 1 ))
  sleep 1
  if nmap -p22 ${TOWER_VM_IP} | grep  "22/tcp.*open"
  then
    break
  fi
  if [ $counter -gt $TIMEOUT ]
  then
    echo ERROR: something went wrong - check console
    exit 1
  elif [ $counter -gt $TIMEOUT_WARN ]
  then
    echo WARN: this is taking longer than expected
  fi
  echo -n "."
done
echo ""

# Copy SSH public key
cmd sshpass -p ${PASSWORD} ssh-copy-id ${SSH_OPTS} root@${TOWER_VM_IP}

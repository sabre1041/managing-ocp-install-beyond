#!/bin/bash

source group_vars_all

# Copy the rhel-guest-image from the NFS location to /tmp
cmd wget --continue --directory-prefix=/tmp ${BASE_IMAGE_URL}

# Create empty image which will be used for the virt-resize
cmd qemu-img create -f qcow2 /var/lib/libvirt/images/${OSP_IMAGE_NAME} ${OSP_VM_TOTAL_DISK_SIZE}
# List partition on rhel-guest-image
cmd virt-filesystems --partitions -h --long -a /tmp/${BASE_IMAGE_NAME}
# Resize rhel-guest-image sda1 to ${OSP_VM_ROOT_DISK_SIZE} into the created qcow. The remaining space will become sda2
cmd virt-resize --resize /dev/sda1=${OSP_VM_ROOT_DISK_SIZE} /tmp/${BASE_IMAGE_NAME} /var/lib/libvirt/images/${OSP_IMAGE_NAME}
# List partitions on new image
cmd virt-filesystems --partitions -h --long -a /var/lib/libvirt/images/${OSP_IMAGE_NAME}
# Show disk spac eon new image
cmd virt-df -a /var/lib/libvirt/images/${OSP_IMAGE_NAME}
# Set password, set hostname, remove cloud-init, configure rhos-release, and setup networking
cmd virt-customize -a /var/lib/libvirt/images/${OSP_IMAGE_NAME} \
  --root-password password:${PASSWORD} \
  --hostname ${OSP_VM_HOSTNAME} \
  --run-command 'yum remove cloud-init* -y && \
    rpm -ivh http://rhos-release.virt.bos.redhat.com/repos/rhos-release/rhos-release-latest.noarch.rpm && \
    rhos-release 10 && \
    echo "DEVICE=eth1" > /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    echo "BOOTPROTO=static" >> /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    echo "ONBOOT=yes" >> /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    echo "IPADDR=172.20.17.10" >> /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    echo "NETMASK=255.255.255.0" >> /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    systemctl disable NetworkManager'

# Install image as VM
cmd virt-install --ram 32768 --vcpus 8 --os-variant rhel7 \
  --disk path=/var/lib/libvirt/images/${OSP_IMAGE_NAME},device=disk,bus=virtio,format=qcow2 \
  --import --noautoconsole --vnc \
  --cpu host,+vmx \
  --network network:${LAB_NAME}-admin \
  --network network:${LAB_NAME}-osp \
  --name ${LAB_NAME}

echo -n "Waiting for VM to come online"
counter=0
while :
do
  counter=$(( $counter + 1 ))
  sleep 1
  OSP_VM_IP=$(virsh domifaddr ${LAB_NAME} | grep 192.168.144 | awk '{print $4}'| cut -d/ -f1)
  if [ ! -z ${OSP_VM_IP} ]
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

echo -n "Waiting for sshd to be available"
counter=0
while :
do
  counter=$(( $counter + 1 ))
  sleep 1
  if nmap -p22 ${OSP_VM_IP} | grep  "22/tcp.*open"
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
cmd sshpass -p ${PASSWORD} ssh-copy-id ${SSH_OPTS} root@${OSP_VM_IP}

# Copy guest image to VM
cmd scp ${SSH_OPTS} /tmp/${BASE_IMAGE_NAME} root@${OSP_VM_IP}:/tmp/.

# Copy openstack-scripts to VM
cmd rsync -e "ssh ${SSH_OPTS}" -avP openstack-scripts/ root@${OSP_VM_IP}:/root/openstack-scripts/

# Install and configure the OpenStack environment for the lab (create user, project, fix Cinder to use LVM, etc)
ssh -t ${SSH_OPTS} root@${OSP_VM_IP} /root/openstack-scripts/openstack-env-config.sh

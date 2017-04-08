#!/bin/bash

source group_vars_all

# Check for SSH keys
if [ ! -f ${SSH_KEY_FILENAME} ]
then
  echo "ERROR: ${SSH_KEY_FILENAME} not present, run 'deploy-kvm-host-config.sh' first"
  exit 1
fi

# Fetch the base image
cmd wget --continue -O ${OSP_BASE_IMAGE_PATH} ${OSP_BASE_IMAGE_URL}

# Create empty image which will be used for the virt-resize
cmd qemu-img create -f qcow2 ${OSP_VM_IMAGE_PATH} ${OSP_VM_TOTAL_DISK_SIZE}

# List partition on rhel-guest-image
cmd virt-filesystems --partitions -h --long -a ${OSP_BASE_IMAGE_PATH}

# Resize rhel-guest-image sda1 to ${OSP_VM_ROOT_DISK_SIZE} into the created qcow. The remaining space will become sda2
cmd virt-resize --resize /dev/sda1=${OSP_VM_ROOT_DISK_SIZE} ${OSP_BASE_IMAGE_PATH} ${OSP_VM_IMAGE_PATH}

# List partitions on new image
cmd virt-filesystems --partitions -h --long -a ${OSP_VM_IMAGE_PATH}

# Show disk space on new image
cmd virt-df -a ${OSP_VM_IMAGE_PATH}

# Set password, set hostname, remove cloud-init, configure rhos-release, and setup networking
cmd virt-customize -a ${OSP_VM_IMAGE_PATH} \
  --hostname ${OSP_VM_HOSTNAME} \
  --root-password password:${PASSWORD} \
  --ssh-inject root:file:${SSH_KEY_FILENAME}.pub \
  --selinux-relabel \
  --run-command 'yum remove cloud-init* -y && \
    rpm -ivh http://rhos-release.virt.bos.redhat.com/repos/rhos-release/rhos-release-latest.noarch.rpm && \
    rhos-release 10 && \
    echo "DEVICE=eth1" > /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    echo "BOOTPROTO=static" >> /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    echo "ONBOOT=yes" >> /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    echo "IPADDR=172.20.17.10" >> /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    echo "NETMASK=255.255.255.0" >> /etc/sysconfig/network-scripts/ifcfg-eth1 && \
    systemctl disable NetworkManager'

# Call deploy_vm function
deploy_vm ${OSP_NAME}

# Copy guest image to VM
cmd scp ${SSH_OPTS} ${OSP_BASE_IMAGE_PATH} root@${OSP_VM_HOSTNAME}:/tmp/.

# Remove base image to conserve space
rm -f ${OSP_BASE_IMAGE_PATH}

# Copy openstack-scripts to VM
cmd rsync -e "ssh ${SSH_OPTS}" -avP openstack-scripts/ root@${OSP_VM_HOSTNAME}:/root/openstack-scripts/

# Install and configure the OpenStack environment for the lab (create user, project, fix Cinder to use LVM, etc)
ssh -t ${SSH_OPTS} root@${OSP_VM_HOSTNAME} /root/openstack-scripts/openstack-env-config.sh

# Shutdown the VM
cmd virsh destroy ${OSP_VM_NAME}

# OSP VM takes a while to shutdown
SHUTDOWN_TIMEOUT=600
echo -n "Waiting for ${OSP_VM_NAME} VM to shutdown"
counter=0
while :
do
  counter=$(( $counter + 1 ))
  sleep 1

  if [ -z ${OSP_VM_NAME} ]
  then
    break
  fi

  if [ $counter -gt $SHUTDOWN_TIMEOUT ]
  then
    echo ERROR: something went wrong - check console
    exit 1
  fi

  echo -n "."
done
echo ""

# Sparsify and copy the image to the fileshare
cmd virt-sparsify ${OSP_VM_IMAGE_PATH} ${FILESHARE_DEST_BASE}/${OSP_VM_NAME}/${OSP_VM_IMAGE_NAME}

source remove-rhosp-vm.sh

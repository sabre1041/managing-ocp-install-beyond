#!/bin/bash

source group_vars_all

# Call prep_vm function
prep_vm BASE

# Create empty image which will be used for the virt-resize
cmd qemu-img create -f qcow2 /var/lib/libvirt/images/${OSP_IMAGE_NAME} ${OSP_VM_TOTAL_DISK_SIZE}

# List partition on rhel-guest-image
cmd virt-filesystems --partitions -h --long -a ${IMAGE_LOCAL_DIR}/${BASE_IMAGE_NAME}

# Resize rhel-guest-image sda1 to ${OSP_VM_ROOT_DISK_SIZE} into the created qcow. The remaining space will become sda2
cmd virt-resize --resize /dev/sda1=${OSP_VM_ROOT_DISK_SIZE} ${IMAGE_LOCAL_DIR}/${BASE_IMAGE_NAME} /var/lib/libvirt/images/${OSP_IMAGE_NAME}

# List partitions on new image
cmd virt-filesystems --partitions -h --long -a /var/lib/libvirt/images/${OSP_IMAGE_NAME}

# Show disk space on new image
cmd virt-df -a /var/lib/libvirt/images/${OSP_IMAGE_NAME}

# Set password, set hostname, remove cloud-init, configure rhos-release, and setup networking
cmd virt-customize -a /var/lib/libvirt/images/${OSP_IMAGE_NAME} \
  --root-password password:${PASSWORD} \
  --ssh-inject root:file:${SSH_KEY_FILENAME}.pub \
  --selinux-relabel \
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

# Call deploy_vm function
deploy_vm OSP 32768 8

# Copy guest image to VM
cmd scp ${SSH_OPTS} ${IMAGE_LOCAL_DIR}/${BASE_IMAGE_NAME} root@${OSP_VM_IP}:/tmp/.

# Remove base image to conserve space
rm -f ${IMAGE_LOCAL_DIR}/${BASE_IMAGE_NAME}

# Copy openstack-scripts to VM
cmd rsync -e "ssh ${SSH_OPTS}" -avP openstack-scripts/ root@${OSP_VM_IP}:/root/openstack-scripts/

# Install and configure the OpenStack environment for the lab (create user, project, fix Cinder to use LVM, etc)
ssh -t ${SSH_OPTS} root@${OSP_VM_IP} /root/openstack-scripts/openstack-env-config.sh

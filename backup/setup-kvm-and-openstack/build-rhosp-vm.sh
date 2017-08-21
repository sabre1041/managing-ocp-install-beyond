#!/bin/bash

source group_vars_all

# Check for SSH keys
if [ ! -f ${SSH_KEY_FILENAME} ]
then
  echo "ERROR: ${SSH_KEY_FILENAME} not present, run 'deploy-kvm-host-config.sh' first"
  exit 1
fi

# Check if VM is already defined
if virsh list | grep -q ${OSP_VM_NAME}
then
  echo "ERROR: ${OSP_VM_NAME} already exists. To remove it run the 'remove-rhosp.sh' script."
  exit 1
fi

# If no ssh-agent is running, start one and load the private key
if [ -z "${SSH_AUTH_SOCK}" ]
then
 eval "$(ssh-agent -s)"
  ssh-add ${SSH_KEY_FILENAME}
fi

# Fetch the base image
cmd wget --continue -O ${OSP_BASE_IMAGE_PATH} ${OSP_BASE_IMAGE_URL}

# Fetch the openshift image
cmd wget --continue -O ${OPENSHIFT_IMAGE_PATH} ${OPENSHIFT_IMAGE_URL}

# Fetch Tower public key
cmd wget -O ${IMAGE_STAGING_DIR}/${TOWER_PUBLIC_KEY} ${TOWER_PUBLIC_KEY_URL}

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
  --run-command 'yum remove cloud-init* -y && \
    rpm -ivh http://rhos-release.virt.bos.redhat.com/repos/rhos-release/rhos-release-latest.noarch.rpm && \
    rhos-release 10 && \
    systemctl disable NetworkManager' \
  --write /etc/sysconfig/network-scripts/ifcfg-eth1:'DEVICE=eth1
BOOTPROTO=static
ONBOOT=yes
PEERDNS=no
IPADDR='"${VM_IP[rhosp]}"'
NETMASK=255.255.255.0
GATEWAY=172.20.17.1
DNS1=172.20.17.1
' \
  --selinux-relabel

# Call deploy_vm function
deploy_vm ${OSP_NAME}

# Inject SSH Key
cmd virt-customize -a ${OPENSHIFT_IMAGE_PATH} \
  --root-password password:${PASSWORD} \
  --hostname ${OPENSHIFT_VM_HOSTNAME} \
  --ssh-inject root:file:${IMAGE_STAGING_DIR}/${TOWER_PUBLIC_KEY} \
  --selinux-relabel

# Copy openshift-base image to VM
cmd scp ${SSH_OPTS} ${OPENSHIFT_IMAGE_PATH} root@${OSP_VM_HOSTNAME}:${OPENSHIFT_IMAGE_PATH}

# Remove OpenShift image
cmd rm -fv ${OPENSHIFT_IMAGE_PATH}

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
VM_DESTROYED=""
while :
do
  VM_DESTROYED=$(virsh list --all | grep "${OSP_VM_NAME}")
  if echo ${VM_DESTROYED} | grep -qi "shut off"
  then
    break
  fi
  if [ "$counter" -gt "$SHUTDOWN_TIMEOUT" ]
  then
    echo ""
    echo ERROR: something went wrong - check console
    exit 1
  fi
  counter=$(( $counter + 1 ))
  echo -n "."
  sleep 1
done
echo ""

# Inject key for user
cmd virt-customize -a ${VM_IMAGE_PATH} \
  --ssh-inject user1:file:${SSH_KEY_FILENAME}.pub \
  --selinux-relabel

# Remove image if it exists
DATETIME=$(date +%Y%m%d%H%M%S)
if [ -f ${FILESHARE_DEST_BASE}/${OSP_VM_NAME}/${OSP_VM_IMAGE_NAME}.${DATETIME} ]
then
  echo "WARNING: ${FILESHARE_DEST_BASE}/${OSP_VM_NAME}/${OSP_VM_IMAGE_NAME}.${DATETIME} file exists, remove first?"
  rm -iv ${FILESHARE_DEST_BASE}/${OSP_VM_NAME}/${OSP_VM_IMAGE_NAME}.${DATETIME}
elif [ -L ${FILESHARE_DEST_BASE}/${OSP_VM_NAME}/${OSP_VM_IMAGE_NAME} ]
then
  echo "WARNING: ${FILESHARE_DEST_BASE}/${OSP_VM_NAME}/${OSP_VM_IMAGE_NAME} link exists, remove first?"
  rm -iv ${FILESHARE_DEST_BASE}/${OSP_VM_NAME}/${OSP_VM_IMAGE_NAME}
fi
cmd rsync -avP ${OSP_VM_IMAGE_PATH} ${FILESHARE_DEST_BASE}/${OSP_VM_NAME}/${OSP_VM_IMAGE_NAME}.${DATETIME}

# Create symlink to new image
pushd ${FILESHARE_DEST_BASE}/${OSP_VM_NAME}/
ln -s ${OSP_VM_IMAGE_NAME}.${DATETIME} ${OSP_VM_IMAGE_NAME}
popd

# Remove running rhosp guest
source remove-rhosp-vm.sh

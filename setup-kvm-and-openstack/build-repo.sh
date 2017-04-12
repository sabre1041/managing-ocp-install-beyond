#!/bin/bash

source group_vars_all

if [ -n "${USE_RHSM}" ]
then
  if [ ! -z "${RSHM_USER}" ]
  then
    echo "ERROR: ${RHSM_USER} not present in env."
    exit 1
  fi

  if [ ! -z "${RSHM_PASSWORD}" ]
  then
    echo "ERROR: ${RHSM_PASSWORD} not present in env."
    exit 1
  fi

  if [ ! -z "${RSHM_POOL}" ]
  then
    echo "ERROR: ${RHSM_POOL} not present in env."
    exit 1
  fi
fi

# Check for SSH keys
if [ ! -f ${SSH_KEY_FILENAME} ]
then
  echo "ERROR: ${SSH_KEY_FILENAME} not present, run 'deploy-kvm-host-config.sh' first"
  exit 1
fi

# Check if VM is already defined
if virsh list | grep -q ${REPO_VM_NAME}
then
  echo "ERROR: ${REPO_VM_NAME} already exists. To remove it run the 'remove-rhosp.sh' script."
  exit 1
fi

# If no ssh-agent is running, start one and load the private key
if [ -z "${SSH_AUTH_SOCK}" ]
then
 eval "$(ssh-agent -s)"
  ssh-add ${SSH_KEY_FILENAME}
fi

if [ $USE_FILESHARE == true ]
then
  # Fetch the base image
  cmd wget --continue -O ${REPO_BASE_IMAGE_PATH} ${REPO_BASE_IMAGE_URL}
else
  if [ ! -f ${REPO_BASE_IMAGE_PATH} ]
  then
    echo "ERROR: images need to be pre-staged if USE_FILEESHARE is false"
  fi
fi

if [ $REFRESH_BUILD == false ]
then
  # Create empty image which will be used for the virt-resize
  cmd qemu-img create -f qcow2 ${REPO_VM_IMAGE_PATH} ${REPO_VM_TOTAL_DISK_SIZE}

  # List partition on rhel-guest-image
  cmd virt-filesystems --partitions -h --long -a ${REPO_BASE_IMAGE_PATH}

  # Resize rhel-guest-image sda1 to ${REPO_VM_ROOT_DISK_SIZE} into the created qcow. The remaining space will become sda2
  cmd virt-resize --expand /dev/sda1 ${REPO_BASE_IMAGE_PATH} ${REPO_VM_IMAGE_PATH}

  # List partitions on new image
  cmd virt-filesystems --partitions -h --long -a ${REPO_VM_IMAGE_PATH}

  # Show disk space on new image
  cmd virt-df -a ${REPO_VM_IMAGE_PATH}
else
  # Shutdown the VM
  cmd virsh destroy ${REPO_VM_NAME}

  SHUTDOWN_TIMEOUT=${TIMEOUT}
  echo -n "Waiting for ${REPO_VM_NAME} VM to shutdown"
  counter=0
  VM_DESTROYED=""
  while :
  do
    VM_DESTROYED=$(virsh list --all | grep "${REPO_VM_NAME}")
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
fi

MIRRORED_REPOS='rhel-7-server-rpms rhel-7-server-extras-rpms rhel-7-server-ose-3.4-rpms'
REPOS_TO_ENABLE=''
for repo in ${MIRRORED_REPOS}
do
  REPOS_TO_ENABLE+="--enable ${repo} "
done

# Set password, set hostname, remove cloud-init, configure rhos-release, and setup networking
cmd virt-customize -a ${REPO_VM_IMAGE_PATH} \
  --hostname ${REPO_VM_HOSTNAME} \
  --root-password password:${PASSWORD} \
  --ssh-inject root:file:${SSH_KEY_FILENAME}.pub \
  --mkdir /var/www/html/pub \
  --sm-credentials ${RHSM_USER}:password:${RHSM_PASSWORD} \
  --sm-register \
  --sm-attach pool:${RHSM_POOL} \
  --run-command "yum-config-manager --disable \* ${REPOS_TO_ENABLE}" \
  --install yum-utils,createrepo,httpd \
  --run-command "systemctl enable httpd && systemctl start httpd" \
  --run-command 'yum remove cloud-init* -y' \
  --write /etc/sysconfig/network-scripts/ifcfg-eth1:'DEVICE=eth1
BOOTPROTO=static
ONBOOT=yes
PEERDNS=no
IPADDR='"${VM_IP[repo]}"'
NETMASK=255.255.255.0
GATEWAY=172.20.17.1
DNS1=172.20.17.1
' \
  --run-command 'reposync -p /var/www/html/pub -r rhel-7-server-rpms' \
  --run-command 'pushd /var/www/html/pub/rhel-7-server-rpms && createrepo . && popd' \
  --run-command 'reposync -p /var/www/html/pub -r rhel-7-server-extras-rpms' \
  --run-command 'pushd /var/www/html/pub/rhel-7-server-extras-rpms && createrepo . && popd' \
  --run-command 'reposync -p /var/www/html/pub -r rhel-7-server-ose-3.4-rpms' \
  --run-command 'pushd /var/www/html/pub/rhel-7-server-ose-3.4-rpms && createrepo . && popd' \
  --sm-unregister \
  --selinux-relabel

# Call deploy_vm function
deploy_vm ${REPO_NAME}

# TODO: Post-deploy config goes here

if [ ${UPDATE_FILESHARE} ]
then
  # Shutdown the VM
  cmd virsh destroy ${REPO_VM_NAME}

  SHUTDOWN_TIMEOUT=${TIMEOUT}
  echo -n "Waiting for ${REPO_VM_NAME} VM to shutdown"
  counter=0
  VM_DESTROYED=""
  while :
  do
    VM_DESTROYED=$(virsh list --all | grep "${REPO_VM_NAME}")
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

  # Copy image
  cmd rsync -avP ${REPO_VM_IMAGE_PATH} ${FILESHARE_DEST_BASE}/${REPO_VM_NAME}/${REPO_VM_IMAGE_NAME}

  # Remove running repo guest
  source remove-repo-vm.sh

  # Remove image in /tmp so new one will be pulled next time
  rm -fv /tmp/L104353-repo.qcow2
fi



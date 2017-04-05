#!/bin/bash

# Set variables
VERBOSE=true
DEBUG=false
LAB_NAME=L104353
OSP_VM_TOTAL_DISK_SIZE=100G
OSP_VM_ROOT_DISK_SIZE=30G
OSP_VM_HOSTNAME=rhosp.admin.example.com
OSP_IMAGE_NAME=${LAB_NAME}-rhel7-rhosp10.qcow2
SSH_KEY_FILENAME=~/.ssh/${LAB_NAME}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY_FILENAME}"
PASSWORD=summit2017
TIMEOUT=30
TIMEOUT_WARN=15
BASE_IMAGE_NAME=rhel-guest-image-7.3-35.x86_64.qcow2
BASE_IMAGE_URL=http://10.11.169.10/fileshare/images/${BASE_IMAGE_NAME}

# Load common functions
source openstack-scripts/common-libs

# Run lab-specific commands
source lab-prep.sh

# Set up sshpass for non-interactive deployment
if ! rpm -q sshpass
then
  cmd yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
  cmd yum -y install sshpass
fi

# Install required rpms
cmd yum -y install libvirt qemu-kvm virt-manager virt-install libguestfs-tools xorg-x11-apps xauth virt-viewer libguestfs-xfs dejavu-sans-fonts nfs-utils vim-enhanced rsync nmap bash-completion

# Enable and start libvirt services
cmd systemctl enable libvirtd && systemctl start libvirtd

# Check for and attempt to enable nested virt support
if ! egrep -q '^flags.*(vmx|svm)' /proc/cpuinfo
then
  echo "ERROR: Intel VT or AMD-V was not detected, check BIOS to enable this feature."
  exit 1
fi

# Determine CPU Vendor
if grep -qi intel /proc/cpuinfo
then
  CPU_VENDOR=intel
elif grep -qi amd /proc/cpuinfo
then
  CPU_VENDOR=amd
else
  echo "ERROR: Unable to determine CPU Vendor, try rebooting or ??"
  exit 1
fi

# Check and attempt to enable nested virt
echo "Checking for nested virt support"
if ! egrep -q 'Y|1' /sys/module/kvm_${CPU_VENDOR}/parameters/nested
then
  echo "WARN: Nested virt not enabled, attempting to enable. This may require a reboot if other VMs are running."
  rmmod kvm-${CPU_VENDOR}
  echo "options kvm-${CPU_VENDOR} nested=Y" > /etc/modprobe.d/kvm_${CPU_VENDOR}.conf
  echo "options kvm-${CPU_VENDOR} enable_shadow_vmcs=1" >> /etc/modprobe.d/kvm_${CPU_VENDOR}.conf
  echo "options kvm-${CPU_VENDOR} enable_apicv=1" >> /etc/modprobe.d/kvm_${CPU_VENDOR}.conf
  echo "options kvm-${CPU_VENDOR} ept=1" >> /etc/modprobe.d/kvm_${CPU_VENDOR}.conf
  cmd modprobe kvm-${CPU_VENDOR}
  if egrep -q "N|0" /sys/module/kvm_${CPU_VENDOR}/parameters/nested 
  then
    echo "WARN: Could not dynamically enable nested virt, reboot and re-run this script."
    exit 1
  fi
fi
if ! lsmod | grep -q -e kvm_intel -e kvm_amd
then
  echo "ERROR: CPU Virt extensions not loaded, try rebooting and re-run this script."
fi

# Create Admin Network
cat > /tmp/${LAB_NAME}-admin.xml <<EOF
<network>
  <forward mode='nat'/>
  <name>${LAB_NAME}-admin</name>
  <domain name='admin.example.com' localOnly='yes'/>
  <ip address="192.168.144.1" netmask="255.255.255.0">
    <dhcp>
      <range start='192.168.144.2' end='192.168.144.254'/>
    </dhcp>
  </ip>
</network>
EOF

# Create OpenStack network without DHCP, as OpenStack will provide that via dnsmasq
cat > /tmp/${LAB_NAME}-osp.xml <<EOF
<network>
  <forward mode='nat'/>
  <name>${LAB_NAME}-osp</name>
  <ip address="172.20.17.1" netmask="255.255.255.0"/>
</network>
EOF

# Create OpenStack network
for network in admin osp; do
  cmd virsh net-define /tmp/${LAB_NAME}-${network}.xml
  cmd virsh net-autostart ${LAB_NAME}-${network}
  echo "INFO: If this libvirt network fails to start try restarting libvirtd."
  cmd virsh net-start ${LAB_NAME}-${network}
done

# Ensure the dnsmasq plugin is enabled for NetworkManager
cat > /etc/NetworkManager/conf.d/${LAB_NAME}.conf <<EOF
[main]
dns=dnsmasq
EOF

# Add dnsmasq config for admin network
cat > /etc/NetworkManager/dnsmasq.d/${LAB_NAME}.conf <<EOF
no-negcache
strict-order
server=/admin.example.com/192.168.144.1
server=/osp.example.com/172.20.17.100
address=/master.osp.example.com/172.20.17.5
address=/.apps.example.com/172.20.17.5
EOF

# Restart NetworkManager to pick up the changes
cmd systemctl restart NetworkManager

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
  --name rhelosp

echo -n "Waiting for VM to come online"
counter=0
while :
do
  counter=$(( $counter + 1 ))
  sleep 1
  VM_IP=$(virsh domifaddr rhelosp | grep vnet0 | awk '{print $4}'| cut -d/ -f1)
  if [ ! -z ${VM_IP} ]
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

echo -n "Waiting for sshd to be available"
counter=0
while :
do
  counter=$(( $counter + 1 ))
  sleep 1
  if nmap -p22 ${VM_IP} | grep  "22/tcp.*open"
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

# Setup SSH config to prevent prompting
if [ ! -d ~/.ssh ]
then
  cmd mkdir ~/.ssh
  cmd chmod 600 ~/.ssh
fi

# Create unique key for this project
if [ -e ${SSH_KEY_FILENAME} ]
then
  cmd rm -f ${SSH_KEY_FILENAME}
fi

cmd ssh-keygen -b 2048 -t rsa -f ${SSH_KEY_FILENAME} -N ""

# Copy SSH public key
cmd sshpass -p ${PASSWORD} ssh-copy-id ${SSH_OPTS} root@${VM_IP}

# Copy guest image to VM
cmd scp ${SSH_OPTS} /tmp/${BASE_IMAGE_NAME} root@${VM_IP}:/tmp/.

# Copy openstack-scripts to VM
cmd rsync -e "ssh ${SSH_OPTS}" -avP openstack-scripts/ root@${VM_IP}:/root/openstack-scripts/

# Install and configure the OpenStack environment for the lab (create user, project, fix Cinder to use LVM, etc)
ssh -t ${SSH_OPTS} root@${VM_IP} /root/openstack-scripts/openstack-env-config.sh

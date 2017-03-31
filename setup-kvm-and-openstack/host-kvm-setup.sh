#!/bin/bash

# Set variable for unique SSH key
SSH_KEY_OPTS="$0"

# Set up sshpass for non-interactive deployment
yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
yum -y install sshpass
yum-config-manager --disable "Extra Packages for Enterprise Linux 7 - x86_64"


# Using internal rhos-release so no dependency on Satellite or Hosted
yum -y install http://rhos-release.virt.bos.redhat.com/repos/rhos-release/rhos-release-latest.noarch.rpm
rhos-release rhel-7.3

# Disable lab-specific cobble repos
yum-config-manager --disable core-1 --disable core-2 

# Install required rpms
yum -y install libvirt qemu-kvm virt-manager virt-install libguestfs-tools xorg-x11-apps xauth virt-viewer libguestfs-xfs dejavu-sans-fonts nfs-utils vim-enhanced rsync

# Enable and start libvirt services
systemctl enable libvirtd && systemctl start libvirtd

# For this specific lab environment, mount the fileshare containing images and scripts
mkdir /fileshare
mount 10.11.169.10:/exports/fileshare /fileshare/

# Create OpenStack network without DHCP, as OpenStack will provide that via dnsmasq
cat > /tmp/L104353.xml <<EOF
<network>
  <forward mode='nat'/>
  <name>L104353</name>
  <ip address="172.20.17.1" netmask="255.255.255.0"/>
</network>
EOF

# Create OpenStack network
virsh net-define /tmp/L104353.xml
virsh net-autostart L104353
virsh net-start L104353

# Copy the rhel-guest-image from the NFS location to /tmp
rsync -e "ssh -i ~/.ssh/${SSH_KEY_OPTS%.*}" -avP /fileshare/images/rhel-guest-image-7.3-35.x86_64.qcow2 /tmp/rhel-guest-image-7.3-35.x86_64.qcow2

# Create empty image which will be used for the virt-resize
qemu-img create -f qcow2 /var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2 100G
# List partition on rhel-guest-image
virt-filesystems --partitions -h --long -a /tmp/rhel-guest-image-7.3-35.x86_64.qcow2
# Resize rhel-guest-image sda1 to 30G into the created qcow. The remaining space will become sda2
virt-resize --resize /dev/sda1=30G /tmp/rhel-guest-image-7.3-35.x86_64.qcow2 /var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2
# List partitions on new image
virt-filesystems --partitions -h --long -a /var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2
# Show disk spac eon new image
virt-df -a /var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2
# Set password
virt-customize -a /var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2 --root-password password:summit2017
# Remove cloud-init, configure rhos-release, and setup static IPs
virt-customize -a /var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2 --run-command '\
yum remove cloud-init* -y && \
rpm -ivh http://rhos-release.virt.bos.redhat.com/repos/rhos-release/rhos-release-latest.noarch.rpm && \
rhos-release 10 && \
rhos-release rhel-7.3 && \
yum-config-manager --disable rhelosp-rhel-7.2-extras --disable rhelosp-rhel-7.2-ha --disable rhelosp-rhel-7.2-server --disable rhelosp-rhel-7.2-z --disable rhelosp-rhel-7.3-pre-release && \
echo "DEVICE=eth0" > /etc/sysconfig/network-scripts/ifcfg-eth0 && \
echo "BOOTPROTO=static" >> /etc/sysconfig/network-scripts/ifcfg-eth0 && \
echo "ONBOOT=yes" >> /etc/sysconfig/network-scripts/ifcfg-eth0 && \
echo "IPADDR=192.168.122.10" >> /etc/sysconfig/network-scripts/ifcfg-eth0 && \
echo "NETMASK=255.255.255.0" >> /etc/sysconfig/network-scripts/ifcfg-eth0 && \
echo "DNS1=192.168.122.1" >> /etc/sysconfig/network-scripts/ifcfg-eth0 && \
cp /etc/sysconfig/network-scripts/ifcfg-eth{0,1} && \
echo "GATEWAY=192.168.122.1" >> /etc/sysconfig/network-scripts/ifcfg-eth0 && \
sed -i s/eth0/eth1/g /etc/sysconfig/network-scripts/ifcfg-eth1 && \
sed -i s/192.168.122/172.20.17/g /etc/sysconfig/network-scripts/ifcfg-eth1'

# Install image as VM
virt-install --ram 32768 --vcpus 8 --os-variant rhel7 \
  --disk path=/var/lib/libvirt/images/L104353-rhel7-rhosp10.qcow2,device=disk,bus=virtio,format=qcow2 \
  --import --noautoconsole --vnc \
  --cpu host,+vmx \
  --network network:default \
  --network network:L104353 \
  --name rhelosp

# Setup SSH config to prevent prompting
mkdir ~/.ssh
chmod 600 ~/.ssh
cat > ~/.ssh/config << EOF
host 192.168.122.10
StrictHostKeyChecking no 
UserKnownHostsFile /dev/null
LogLevel QUIET
EOF

# Create unique key for this project
if [ ! -e ~/.ssh/${SSH_KEY_OPTS%.*} ]
then
  ssh-keygen -b 2048 -t rsa -f ~/.ssh/${SSH_KEY_OPTS%.*} -q -N ""
  eval `ssh-agent`
  ssh-add ~/.ssh/${SSH_KEY_OPTS%.*}
fi

echo
echo "Waiting on VM to come online"
echo

# Wait for VM to come online
sleep 40

# Remove any existing entries for static IP
sed -i /192.168.122.10/d ~/.ssh/known_hosts

# Copy SSH public key (TODO: Automate this)
sshpass -p summit2017 ssh-copy-id -i ~/.ssh/${SSH_KEY_OPTS%.*} root@192.168.122.10

# Copy guest image to VM
sshpass -p summit2017 scp /fileshare/images/rhel-guest-image-7.3-35.x86_64.qcow2 root@192.168.122.10:/tmp/.
# Copy openstack-scripts to VM
sshpass -p summit2017 rsync -e "ssh -i ~/.ssh/${SSH_KEY_OPTS%.*}" -avP /fileshare/scripts/summit2017/openstack-scripts/ root@192.168.122.10:/root/openstack-scripts/
# Disable NetworkManager and firewalld
sshpass -p summit2017 ssh root@192.168.122.10 "systemctl disable NetworkManager && systemctl stop NetworkManager && systemctl disable firewalld && systemctl stop firewalld && systemctl enable network && systemctl start network"
# Install Packstack and utils
sshpass -p summit2017 ssh root@192.168.122.10 "yum -y install openstack-packstack openstack-utils"
# Run Packstack using a pseudo terminal
sshpass -p summit2017 ssh -t root@192.168.122.10 "packstack --answer-file=/root/openstack-scripts/answers.txt"
# Configure the OpenStack environment for the lab (create user, project, fix Cinder to use LVM, etc)
sshpass -p summit2017 ssh root@192.168.122.10 /root/openstack-scripts/openstack-env-config.sh


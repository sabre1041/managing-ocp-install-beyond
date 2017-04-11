#!/bin/bash

source group_vars_all

# Run environment-specific commands
#source prep-host-env-config.sh

# Install required rpms
cmd yum -y install libvirt qemu-kvm virt-manager virt-install libguestfs-tools xorg-x11-apps xauth virt-viewer libguestfs-xfs dejavu-sans-fonts nfs-utils vim-enhanced rsync nmap bash-completion numad numactl systat iostat

# Enable and start libvirt services
cmd systemctl enable libvirtd && systemctl start libvirtd

# Enable numad is system supports it
if dmesg | grep -iq numa
then
  systemctl start numad
  systemctl enable numad
fi

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

# Enable virtual-host profile in tuned
cmd tuned-adm active
cmd tuned-adm profile virtual-host
cmd tuned-adm active

# Create Admin Network
cat > /tmp/${LAB_NAME}-admin.xml <<EOF
<network>
  <forward mode='nat'/>
  <name>${LAB_NAME}-admin</name>
  <domain name='${ADMIN_DOMAIN}' localOnly='yes'/>
  <ip address="192.168.144.1" netmask="255.255.255.0">
    <dhcp>
      <range start='192.168.144.2' end='192.168.144.254'/>
    </dhcp>
  </ip>
</network>
EOF

# Create OpenStack network without DHCP, as OpenStack will provide that via dnsmasq
cat > /tmp/${LAB_NAME}-rhosp.xml <<EOF
<network>
  <forward mode='nat'/>
  <name>${LAB_NAME}-rhosp</name>
  <ip address="172.20.17.1" netmask="255.255.255.0"/>
</network>
EOF

# Create OpenStack network
for network in admin rhosp; do
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
server=/${ADMIN_DOMAIN}/192.168.144.1
server=/${OSP_DOMAIN}/172.20.17.100
address=/${WILDCARD_DOMAIN}/172.20.17.6
address=/master.${OSP_DOMAIN}/172.20.17.5
address=/infra.${OSP_DOMAIN}/172.20.17.6
address=/node1.${OSP_DOMAIN}/172.20.17.51
address=/node2.${OSP_DOMAIN}/172.20.17.52
address=/node3.${OSP_DOMAIN}/172.20.17.53
address=/rhosp.${OSP_DOMAIN}/172.20.17.10
address=/repo.${OSP_DOMAIN}/172.20.17.15
address=/tower.${OSP_DOMAIN}/172.20.17.20
EOF

# Restart NetworkManager to pick up the changes
cmd systemctl restart NetworkManager

# Setup SSH config to prevent prompting
if [ ! -d ~/.ssh ]
then
  cmd mkdir ~/.ssh
  cmd chmod 600 ~/.ssh
fi

# Create unique key for this project
if [ ! -f ${SSH_KEY_FILENAME} ]
then
  # Setup lab key
  cmd ssh-keygen -b 2048 -t rsa -f ${SSH_KEY_FILENAME} -N ""
fi

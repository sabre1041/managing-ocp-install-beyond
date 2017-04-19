#!/bin/bash

source group_vars_all

SSD_DISK=sdb
DISK_IS_ROTATIONAL=$(cat /sys/block/${SSD_DISK}/queue/rotational)
DISK_SIZE=400GB

curl -o /tmp/rhos-release-latest.noarch.rpm http://rhos-release.virt.bos.redhat.com/repos/rhos-release/rhos-release-latest.noarch.rpm

if ! rpm -q rhos-release
then
  cmd yum -y localinstall /tmp/rhos-release-latest.noarch.rpm
fi
cmd rhos-release rhel-7.3

# Install packages
cmd yum -y install vim-enhanced screen nfs-utils rsync

# nfs-utils needed for this to work
if ! mount | grep "10.11.169.10:/exports/fileshare/"
then
  mkdir /fileshare/
  cmd mount 10.11.169.10:/exports/fileshare/ /fileshare/
fi

if ! grep "10.11.169.10:/exports/fileshare/" /etc/fstab
then
  echo -e "10.11.169.10:/exports/fileshare/\t/fileshare/\tnfs\tdefaults\t0 0" >> /etc/fstab
fi

if ! rpm -q nfs-utils
then
  cmd yum -y install nfs-utils
fi

# Remove all partitions
if [ "${DISK_IS_ROTATIONAL}" == "0" ]
then
  for part in {4..1}
  do
    parted -s /dev/${SSD_DISK} rm $part
  done
else
  echo "ERROR: Specify an SSD other than ${SSD_DISK}"
  echo "Press ENTER to see all disks on this system"
  lsblk
  exit 1
fi

#Create disk labels
cmd parted -s /dev/${SSD_DISK} mklabel msdos

cmd partprobe -s /dev/${SSD_DISK}

# Create a single partition
cmd parted -a optimal /dev/${SSD_DISK} mkpart primary 0% ${DISK_SIZE}

cmd pvcreate /dev/${SSD_DISK}1
cmd pvs

cmd vgcreate vg_${LAB_NAME} /dev/${SSD_DISK}1
cmd vgs

cmd lvcreate -l100%FREE -n lv_${LAB_NAME} vg_${LAB_NAME}
cmd lvs

cmd mkfs.ext4 /dev/vg_${LAB_NAME}/lv_${LAB_NAME}

cmd lvs
HOME_LVM=$(grep "home /home" /etc/fstab | awk '{print $1}')
if [[ ! -z "$HOME_LVM" ]]
then
  echo INFO: running reclaim home lvm snippet on $HOME_LVM
  umount /home
  lvremove -y ${HOME_LVM}
  sed -i '/\/home/d' /etc/fstab
  ROOT_LVM=$(grep "root /" /etc/fstab | awk '{print $1}')
  lvextend --resizefs --extents +100%FREE ${ROOT_LVM}
  lvs
fi

if [ ! -d /var/lib/libvirt/images/ ]
then
  cmd mkdir -p /var/lib/libvirt/images/
fi

if ! mount | grep "/var/lib/libvirt/images"
then
  cmd mount /dev/vg_${LAB_NAME}/lv_${LAB_NAME} /var/lib/libvirt/images/
fi

if ! grep "/var/lib/libvirt/images" /etc/fstab
then
  echo -e "/dev/vg_${LAB_NAME}/lv_${LAB_NAME}\t/var/lib/libvirt/images\txfs\tdefaults\t0 0" >> /etc/fstab
fi

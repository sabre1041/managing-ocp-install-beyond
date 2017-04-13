#!/bin/bash

SSD_DISK=sdp
DISK_IS_ROTATIONAL=$(cat /sys/block/${SSD_DISK}/queue/rotational)
DISK_SIZE=400GB

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
  echo -e "/dev/vg_${LAB_NAME}/lv_${LAB_NAME}\t/var/lib/libvirt/images\txfs\tdefaults\t0 0" >> /etc/fstab
fi

#!/bin/bash

virsh destroy master-clone 
virsh destroy node-2-clone
virsh destroy node-1-clone
virt-clone --original summit-2017-lab-scollier-gold-image --name master-clone --mac 52:54:00:11:09:c7 --file /var/lib/libvirt/images/master-clone.qcow2
virt-clone --original summit-2017-lab-scollier-gold-image --name node-1-clone --mac 52:54:00:d1:93:7b --file /var/lib/libvirt/images/node-1-clone.qcow2
virt-clone --original summit-2017-lab-scollier-gold-image --name node-2-clone --mac 52:54:00:2f:11:4c --file /var/lib/libvirt/images/node-2-clone.qcow2
virsh start master-clone 
virsh start node-2-clone
virsh start node-1-clone


#!/bin/bash

source group_vars_all

virsh destroy ${TOWER_VM_NAME}
virsh undefine ${TOWER_VM_NAME}
rm -f /var/lib/libvirt/images/${TOWER_IMAGE_NAME}

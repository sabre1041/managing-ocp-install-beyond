#!/bin/bash

source group_vars_all

virsh destroy ${OSP_VM_NAME}
virsh undefine ${OSP_VM_NAME}
rm -f /var/lib/libvirt/images/${OSP_IMAGE_NAME}

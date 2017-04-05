#!/bin/bash

source group_vars_all

virsh destroy ${REPO_VM_NAME}
virsh undefine ${REPO_VM_NAME}
rm -f /var/lib/libvirt/images/${REPO_IMAGE_NAME}

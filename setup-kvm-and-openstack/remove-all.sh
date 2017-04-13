#/bin/bash

source group_vars_all

source remove-rhosp-vm.sh
source remove-repo-vm.sh
source remove-tower-vm.sh
source remove-kvm-host-config.sh

echo "INFO: Leave images to speed up deploy scripts. Remove images only if using build scripts."
rm -iv /tmp/${LAB_NAME}-*.qcow2

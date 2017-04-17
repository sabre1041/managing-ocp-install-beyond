#/bin/bash

source group_vars_all

source remove-rhosp-vm.sh
source remove-repo-vm.sh
source remove-tower-vm.sh
source remove-kvm-host-config.sh

echo "INFO: Leave local images to speed up deploy scripts."
echo "INFO: Remove local images to retrieve updated images or if using build scripts."
rm -iv /tmp/${LAB_NAME}-*.qcow2

#/bin/bash

source group_vars_all

source remove-rhosp-vm.sh
source remove-repo-vm.sh
source remove-tower-vm.sh
source remove-kvm-host-config.sh

rm -fv /tmp/L104353-*.qcow2

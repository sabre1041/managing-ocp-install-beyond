#!/bin/bash
virsh destroy rhelosp
virsh undefine rhelosp
rm -f /var/lib/liimages/L104353-rhel7-rhosp10.qcow2
sed -i /192.168.122.10/d ~/.ssh/known_hosts

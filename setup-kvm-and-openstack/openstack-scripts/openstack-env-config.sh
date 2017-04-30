#!/bin/bash

LOGFILE=/root/deploy-openstack-$(hostname -s)-$(date +%F_%H-%M-%S).log
# Load commons-libs first
source /root/openstack-scripts/common-libs
# Load a scenario
source /root/openstack-scripts/scenario-all-in-one
if [[ -z "${CONTROLLER_HOST}" ]]
then
	echo "ERROR: Controller IP not loaded properly!" 2>&1 | tee -a ${LOGFILE}
	exit 1
fi

prep() {
  # Determine CPU Vendor
  if grep -qi intel /proc/cpuinfo
  then
    CPU_VENDOR=intel
  elif grep -qi amd /proc/cpuinfo
  then
    CPU_VENDOR=amd
  else
    echo "ERROR: Unable to determine CPU Vendor, try rebooting or ??"
    exit 1
  fi
  # Check and attempt to enable nested virt
  echo "WARN: Nested virt not enabled, attempting to enable. This may require a reboot."
  rmmod kvm-${CPU_VENDOR}
  echo "options kvm-${CPU_VENDOR} nested=Y" > /etc/modprobe.d/kvm_${CPU_VENDOR}.conf
  echo "options kvm-${CPU_VENDOR} enable_shadow_vmcs=1" >> /etc/modprobe.d/kvm_${CPU_VENDOR}.conf
  echo "options kvm-${CPU_VENDOR} enable_apicv=1" >> /etc/modprobe.d/kvm_${CPU_VENDOR}.conf
  echo "options kvm-${CPU_VENDOR} ept=1" >> /etc/modprobe.d/kvm_${CPU_VENDOR}.conf
  cmd modprobe kvm-${CPU_VENDOR}
  if egrep -q "N|0" /sys/module/kvm_${CPU_VENDOR}/parameters/nested
  then
    echo "WARN: Could not dynamically enable nested virt, reboot to attempt to enable."
    exit 1
  fi
  if ! lsmod | grep -q -e kvm_intel -e kvm_amd
  then
    echo "WARN: CPU Virt extensions not loaded, try rebooting to enable."
  fi

  # Enable lvm on second partition
  cmd pvcreate /dev/sda2
  cmd vgcreate cinder-volumes /dev/sda2
  cmd vgchange -ay
}

packstack-install() {
  # Install Packstack and utils
  cmd yum -y install openstack-packstack openstack-utils

  # Run Packstack - pulled out of function as it was hanging, called in main script
#  cmd packstack --answer-file=/root/openstack-scripts/answers.txt
}

post-install-config() {
	cmd echo "INFO: Starting function 'prepare-host'"

	openstack-config --set /etc/cinder/cinder.conf lvm volume_clear none
	openstack-config --set /etc/cinder/cinder.conf lvm image_upload_use_cinder_backend True
	openstack-config --set /etc/cinder/cinder.conf lvm lvm_type thin
	openstack-config --set /etc/cinder/cinder.conf DEFAULT glance_api_version 2
	openstack-config --set /etc/cinder/cinder.conf DEFAULT allowed_direct_url_schemes cinder
	openstack-config --set /etc/glance/glance-api.conf glance_store stores file,http,swift,cinder
	openstack-config --set /etc/glance/glance-api.conf DEFAULT show_multiple_locations True
	openstack-config --set /etc/nova/nova.conf DEFAULT scheduler_default_filters RetryFilter,AvailabilityZoneFilter,RamFilter,ComputeFilter,ComputeCapabilitiesFilter,ImagePropertiesFilter,ServerGroupAntiAffinityFilter,ServerGroupAffinityFilter,CoreFilter
	openstack-config --set /etc/nova/nova.conf libvirt virt_type kvm
	openstack-config --set /etc/nova/nova.conf libvirt cpu_mode host-passthrough
	openstack-config --set /etc/nova/nova.conf libvirt hw_disk_discard unmap
	openstack-config --set /etc/nova/nova.conf libvirt use_usb_tablet false
	openstack-config --set /etc/nova/nova.conf DEFAULT block_device_allocate_retries 120
	openstack-config --set /etc/nova/nova.conf DEFAULT block_device_allocate_retries_interval 10
	if "${EXTERNAL_ONLY}" == "true"
	then
		openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata true
	fi
	cmd openstack-service restart
  cmd useradd ${USERNAME}
  cmd usermod ${USERNAME} -G wheel
  echo "${PASSWORD}" | passwd ${USERNAME} --stdin
  cmd sed -i 's/cloud-user/user1/g' /etc/sudoers
  # Remove repos
  cmd rhos-release -x
  cmd yum -y remove rhos-release
}

post-install-admin-tasks() {
	cmd echo "INFO: Starting function 'post-install-admin-tasks'"
	source /root/keystonerc_admin
	if ! openstack project list | grep ${TENANT_NAME}
	then
		cmd openstack project create ${TENANT_NAME}
	fi
	if ! openstack user list | grep ${USERNAME}
	then
		cmd openstack user create ${USERNAME} --password ${PASSWORD}
		cmd openstack role add --user ${USERNAME} --project ${TENANT_NAME} _member_
		cmd openstack role add --user admin --project ${TENANT_NAME} _member_
	fi
	if ! neutron net-list | grep external
	then
		SERVICES_TENANT_ID=$(openstack project list | awk '/services/ {print $2}')
		if [[ "${PROVIDER_TYPE}" == "vlan" ]]
		then
			cmd neutron net-create external --provider:network_type ${PROVIDER_TYPE} --provider:physical_network ${PROVIDER_NETWORK} --shared ${EXTERNAL_SHARED} --provider:segmentation_id ${PROVIDER_VLAN} --router:external=True --tenant-id ${SERVICES_TENANT_ID}
		else
			cmd neutron net-create external --provider:network_type ${PROVIDER_TYPE} --provider:physical_network ${PROVIDER_NETWORK} --shared --router:external=True --tenant-id ${SERVICES_TENANT_ID}
		fi
		cmd neutron subnet-create \
		  --name external \
		  --allocation-pool start=${FLOATING_POOL_START},end=${FLOATING_POOL_END} \
		  ${EXTERNAL_DHCP} \
		  --gateway ${EXTERNAL_GATEWAY} \
		  --dns=${EXTERNAL_DNS} \
		  external \
		  ${EXTERNAL_NETWORK}
	fi
  TENANT_ID=$(openstack project show ${TENANT_NAME} -f value -c id)
  EXTERNAL_SUBNET_ID=$(openstack subnet show external -f value -c id)

  #Create port for openshift master
  cmd neutron port-create external --name openshift-master --tenant-id ${TENANT_ID} --allowed-address-pairs type=dict list=true ip_address=172.20.17.5 --fixed-ip subnet_id=${EXTERNAL_SUBNET_ID},ip_address=172.20.17.5
  cmd neutron port-create external --name openshift-infra --tenant-id ${TENANT_ID} --allowed-address-pairs type=dict list=true ip_address=172.20.17.6 --fixed-ip subnet_id=${EXTERNAL_SUBNET_ID},ip_address=172.20.17.6
  cmd neutron port-create external --name openshift-node1 --tenant-id ${TENANT_ID} --allowed-address-pairs type=dict list=true ip_address=172.20.17.51 --fixed-ip subnet_id=${EXTERNAL_SUBNET_ID},ip_address=172.20.17.51
  cmd neutron port-create external --name openshift-node2 --tenant-id ${TENANT_ID} --allowed-address-pairs type=dict list=true ip_address=172.20.17.52 --fixed-ip subnet_id=${EXTERNAL_SUBNET_ID},ip_address=172.20.17.52
  cmd neutron port-create external --name openshift-node3 --tenant-id ${TENANT_ID} --allowed-address-pairs type=dict list=true ip_address=172.20.17.53 --fixed-ip subnet_id=${EXTERNAL_SUBNET_ID},ip_address=172.20.17.53

  #Increase quota for volumes
  cmd openstack quota set --volumes 20 ${TENANT_NAME}

	# User keystonerc file
cat > /root/keystonerc_${USERNAME} << EOF
export OS_USERNAME=${USERNAME}
export OS_TENANT_NAME=${TENANT_NAME}
export OS_PASSWORD=${PASSWORD}
export OS_AUTH_URL=http://${CONTROLLER_HOST}:35357/v2.0/
export PS1='[\u@\h \W(keystone_${USERNAME})]\$ '
EOF
echo "source /root/keystonerc_${USERNAME}">> /root/.bashrc
echo "source /home/${USERNAME}/keystonerc_${USERNAME}">> /home/${USERNAME}/.bashrc
cp /root/keystonerc_${USERNAME} /home/${USERNAME}/.
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/keystonerc_${USERNAME}
}

create-images() {
  # image creation
  cmd echo "INFO: Starting function 'create-images'"
  source /root/keystonerc_${USERNAME}

  if ! glance image-list | grep image-base-src
  then
    cmd openstack image create \
      --disk-format raw \
      --container-format bare \
      --property hw_scsi_model=virtio-scsi \
      --property hw_disk_bus=scsi \
      --min-disk 10 \
      --file ${OPENSHIFT_IMAGE_PATH} \
      image-base-src
  fi
	# wait for image to become active
	echo -en "\nWaiting for image to create"
  counter=0
	while :
	do
    counter=$(( $counter + 1 ))
		echo -n "."
		sleep 1
	  if openstack image show image-base-src -f value -c status | grep -q active
    then
      break
    fi
    if [ $counter -gt $TIMEOUT ]
    then
      echo ERROR: something went wrong - check console
      exit 1
    elif [ $counter -eq $TIMEOUT_WARN ]
    then
      echo -n "WARN: this is taking longer than expected"
    fi
	done
	echo ""
  if ! glance image-list | grep ${OPENSHIFT_VM_NAME}
  then
    cmd openstack volume create \
      --image image-base-src \
      --size 10 \
      ${OPENSHIFT_VM_NAME}
    cmd openstack image create \
      --disk-format raw \
      --protected \
      --container-format bare \
      --property hw_scsi_model=virtio-scsi \
      --property hw_disk_bus=scsi \
      --min-disk 10 \
      ${OPENSHIFT_VM_NAME}
    echo -en "\nWaiting for volume to create"
    counter=0
    while :
    do
      counter=$(( $counter + 1 ))
      echo -n "."
      sleep 1
      if openstack volume show ${OPENSHIFT_VM_NAME} -f value -c status | grep -q available
      then
        break
      fi
      if [ $counter -gt $TIMEOUT ]
      then
        echo ERROR: something went wrong - check console
        exit 1
      elif [ $counter -eq $TIMEOUT_WARN ]
      then
        echo -n "WARN: this is taking longer than expected"
      fi
    done
    echo ""
    VOLUME_ID=$(openstack volume show ${OPENSHIFT_VM_NAME} -f value -c id)
    IMAGE_ID=$(openstack image show ${OPENSHIFT_VM_NAME} -f value -c id)
    if openstack image list | grep -qi error
    then
      echo "ERROR: Image creation failed"
      exit 1
    fi
    if openstack volume list | grep -qi error
    then
      echo "ERROR: Volume creation failed"
      exit 1
    fi
    cmd glance location-add ${IMAGE_ID} --url cinder://${VOLUME_ID}
    cmd virt-sparsify /dev/cinder-volumes/volume-${VOLUME_ID} --in-place
    cmd openstack image delete image-base-src
  fi
  cmd openstack image show ${OPENSHIFT_VM_NAME}
  cmd rm -vf ${OPENSHIFT_IMAGE_PATH}
}

post-install-user-tasks() {
	cmd echo "INFO: Starting function 'post-install-user-tasks'"
	source ~/keystonerc_${USERNAME}
	if ! nova keypair-list | grep ${USERNAME}
	then
		cmd nova keypair-add ${USERNAME} > ~/${USERNAME}.pem
		chmod 600 ~/${USERNAME}.pem
	fi

	if ! neutron security-group-list | grep icmp
	then
		cmd neutron security-group-rule-create \
			  --protocol icmp \
			  --direction ingress \
			  default
	fi

  if ! neutron security-group-rule-list | grep "65535/tcp"
	then
		cmd neutron security-group-rule-create \
			  --protocol tcp \
			  --port-range-min 1 \
			  --port-range-max 65535 \
			  --direction ingress \
			  default
	fi
  if ! neutron security-group-rule-list | grep "65535/udp"
	then
		cmd neutron security-group-rule-create \
			  --protocol udp \
			  --port-range-min 1 \
			  --port-range-max 65535 \
			  --direction ingress \
			  default
	fi
}

build-instances() {
	cmd echo "INFO: Starting function 'build-instances'"
	source ~/keystonerc_${USERNAME}
  OPENSHIFT_IMAGE_ID=$(openstack image show ${OPENSHIFT_VM_NAME} -f value -c id)
  echo "INFO: Image name: ${OPENSHIFT_VM_NAME} with ID ${OPENSHIFT_IMAGE_ID}"
	glance image-list
	if nova list | grep openshift-base
	then
		nova delete openshift-base
		sleep 5
	fi
  cmd openstack volume create --size 20 openshift-base-volume
  OPENSHIFT_VOL_ID=$(openstack volume list -f value -c ID -c "Display Name" | awk '/openshift-base-volume/ { print $1 }')
	cmd nova boot openshift-base \
    --flavor 2 \
    --poll \
    --key-name ${USERNAME} \
    --image ${OPENSHIFT_IMAGE_ID} \
    --block-device source=volume,id=${OPENSHIFT_VOL_ID},dest=volume,shutdown=remove

	# wait for instances to build
	echo -en "\nWaiting for instances to build "
  counter=0
	while :
	do
    counter=$(( $counter + 1 ))
		echo -n "."
		sleep 1
	  if nova list | grep -qv BUILD
    then
      break
    fi
    if [ $counter -gt $TIMEOUT ]
    then
      echo ERROR: something went wrong - check console
      exit 1
    elif [ $counter -eq $TIMEOUT_WARN ]
    then
      echo -n "WARN: this is taking longer than expected"
    fi
	done
	echo ""
}

verify-networking() {
	source /root/keystonerc_${USERNAME}
	openstack server list
	# Get a VNC console to watch boot sequence if desired
  echo "INFO: View console if desired to watch boot sequence"
	cmd nova get-vnc-console openshift-base novnc

	# Grab the instance ID
	OPENSHIFT_INSTANCE_ID=$(nova list | awk '/openshift-base/ {print $2}')

	# Grab the IP to ping it after instance boot
	OPENSHIFT_IP=$(openstack server list -f value -c Name -c Networks | awk -F= ' /openshift-base/ { print $2 }')
	echo -n "Waiting for instance networking to be available"
  counter=0
  while :
  do
    counter=$(( $counter + 1 ))
    echo -n "."
    sleep 1
    if ping -q -c 2 ${OPENSHIFT_IP} > /dev/null
    then
      break
    fi
    if [ $counter -gt $TIMEOUT ]
    then
      echo "ERROR: something went wrong - check console"
      exit 1
    elif [ $counter -eq $TIMEOUT_WARN ]
    then
      echo -n "WARN: this is taking longer than expected"
    fi
	done
	echo ""

	# Ping the IP
	echo "INFO: Pinging IP for openshift instance: ${OPENSHIFT_IP}"
	cmd ping -c 3 ${OPENSHIFT_IP}
}

cleanup() {
  source /root/keystonerc_${USERNAME}
  cmd openstack server delete openshift-base
  echo -n "Waiting for openshift-base to be deleted"
  counter=0
  while :
  do
    counter=$(( $counter + 1 ))
    echo -n "."
    sleep 1
    if ! openstack server list -f value | grep -q openshift-base
    then
      break
    fi
    if [ $counter -gt $TIMEOUT ]
    then
      echo "ERROR: something went wrong - check console"
      exit 1
    elif [ $counter -eq $TIMEOUT_WARN ]
    then
      echo -n "WARN: this is taking longer than expected"
    fi
  done
  echo ""
  echo -n "Waiting for openshift-base-volume to be deleted"
  counter=0
  while :
  do
    counter=$(( $counter + 1 ))
    echo -n "."
    sleep 1
    if ! openstack volume list -f value | grep -q openshift-base-volume
    then
      break
    fi
    if [ $counter -gt $TIMEOUT ]
    then
      echo "ERROR: something went wrong - check console"
      exit 1
    elif [ $counter -eq $TIMEOUT_WARN ]
    then
      echo -n "WARN: this is taking longer than expected"
    fi
  done
  echo ""
}

# Main
prep 2>&1 | tee -a ${LOGFILE}
packstack-install 2>&1 | tee -a ${LOGFILE}
# For some reason calling this from a function causes packstack to hang on copying puppet modules
cmd packstack --answer-file=/root/openstack-scripts/answers.txt
post-install-config 2>&1 | tee -a ${LOGFILE}
post-install-admin-tasks 2>&1 | tee -a ${LOGFILE}
create-images 2>&1 | tee -a ${LOGFILE}
post-install-user-tasks 2>&1 | tee -a ${LOGFILE}
# Commenting out the following functions intentionally to avoid local image cache creation in /var/lib/nova/instances
#build-instances 2>&1 | tee -a ${LOGFILE}
#source /root/keystonerc_${USERNAME}
#if nova list | grep ERROR
#then
#  echo "ERROR: Something went wrong, check virt capabilities of this host ..."
#  exit 1
#fi
#verify-networking 2>&1 | tee -a ${LOGFILE}
#cleanup 2>&1 | tee -a ${LOGFILE}

echo "INFO: All functions completed" 2>&1 | tee -a ${LOGFILE}

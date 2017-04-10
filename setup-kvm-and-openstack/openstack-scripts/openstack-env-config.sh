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
if [[ ! " ${RHELOSP_VERSIONS[@]} " =~ " ${RHELOSP_VERSION} " ]]
then
  echo "ERROR: Version '${RHELOSP_VERSION}' is not a valid version. Update scenario file." 2>&1 | tee -a ${LOGFILE}
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
}

packstack-install() {
  # Install Packstack and utils
  cmd yum -y install openstack-packstack openstack-utils

  # Run Packstack - pulled out of function as it was hanging, called in main script
#  cmd packstack --answer-file=/root/openstack-scripts/answers.txt
}

post-install-config() {
	cmd echo "INFO: Starting function 'prepare-host'"
	# Remove cinder loopback device and enable lvm on second partition
	CINDER_LODEVICE=$(losetup -l | awk '/cinder-volumes/ { print $1 }')
	losetup -d ${CINDER_LODEVICE}
  rm -f /var/lib/cinder/cinder-volumes
	pvcreate /dev/sda2
	vgcreate cinder-volumes /dev/sda2
	vgchange -ay
	systemctl disable openstack-losetup.service
	systemctl stop openstack-losetup.service
  	openstack-config --set /etc/nova/nova.conf libvirt virt_type kvm
	openstack-config --set /etc/nova/nova.conf DEFAULT scheduler_default_filters RetryFilter,AvailabilityZoneFilter,RamFilter,ComputeFilter,ComputeCapabilitiesFilter,ImagePropertiesFilter,ServerGroupAntiAffinityFilter,ServerGroupAffinityFilter,CoreFilter
	openstack-config --set /etc/cinder/cinder.conf lvm lvm_type thin
	openstack-config --set /etc/cinder/cinder.conf lvm volume_clear none
	openstack-config --set /etc/cinder/cinder.conf lvm image_volume_cache_enabled True
	openstack-config --set /etc/nova/nova.conf DEFAULT block_device_allocate_retries 120
	openstack-config --set /etc/nova/nova.conf DEFAULT block_device_allocate_retries_interval 10
	if "${EXTERNAL_ONLY}" == "true"
	then
		openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata true
	fi
	openstack-service restart
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

	# User keystonerc file
cat > /root/keystonerc_${USERNAME} << EOF
export OS_USERNAME=${USERNAME}
export OS_TENANT_NAME=${TENANT_NAME}
export OS_PASSWORD=${PASSWORD}
export OS_AUTH_URL=http://${CONTROLLER_HOST}:35357/v2.0/
export PS1='[\u@\h \W(keystone_${USERNAME})]\$ '
EOF
}

create-images() {
  # Logging everything except the image creation
	cmd echo "INFO: Starting function 'create-images'" 2>&1 | tee -a ${LOGFILE}
	# The following is needed to address changes in --is-public to --visibility in OSP 8
	RHELOSP_OLD_VERSIONS=(
	"4"
	"5"
	"5-cdn"
	"5-rhel-6"
	"5-rhel-7"
	"6-cdn"
	"6"
	"7-cdn"
	"7"
	)
	RHELOSP_NEW_VERSIONS=(
	"8"
	"9"
	"10"
	)
	if [[ " ${RHELOSP_OLD_VERSIONS[@]} " =~ " ${RHELOSP_VERSION} " ]]
	then
		source /root/keystonerc_admin
		IMAGE_IS_PUBLIC_OPTION="--is-public ${IMAGE_IS_PUBLIC}"
	elif [[ " ${RHELOSP_NEW_VERSIONS[@]} " =~ " ${RHELOSP_VERSION} " ]]
	then
		if [ "${IMAGE_IS_PUBLIC}" = true ]
		then
			source /root/keystonerc_admin
			IMAGE_IS_PUBLIC_OPTION="--visibility public"
		else
			source /root/keystonerc_${USERNAME}
			IMAGE_IS_PUBLIC_OPTION=
		fi
	else
		source /root/keystonerc_${USERNAME}
		IMAGE_IS_PUBLIC_OPTION=
	fi
	if [ "${VERBOSE}" = true ]
	then
		echo "INFO: Setting IMAGE_IS_PUBLIC_OPTION to '${IMAGE_IS_PUBLIC_OPTION}'" 2>&1 | tee -a ${LOGFILE}
	fi
	if ! glance image-list | grep ${CIRROS_IMAGE_NAME}
	then
		cmd curl -o /tmp/${CIRROS_IMAGE_NAME}.img ${CIRROS_IMAGE_URL} 2>&1 | tee -a ${LOGFILE}
		cmd glance image-create \
			 --name ${CIRROS_IMAGE_NAME} \
			 ${IMAGE_IS_PUBLIC_OPTION} \
			 --disk-format qcow2 \
			 --container-format bare \
			 --progress \
			 --file /tmp/${CIRROS_IMAGE_NAME}.img
	fi
	CIRROS_IMAGE_ID=$(glance image-list | grep ${CIRROS_IMAGE_NAME} | awk ' {print $2} ')
  cmd glance image-show ${CIRROS_IMAGE_ID} 2>&1 | tee -a ${LOGFILE}

	if ! glance image-list | grep ${RHEL_IMAGE_NAME}
	then
		cmd yum -y install libguestfs-tools 2>&1 | tee -a ${LOGFILE}
		if [ "${RHEL_IMAGE_INSTALL_LATEST}" = true ]
		then
			cmd yum -y install rhel-guest-image-7 2>&1 | tee -a ${LOGFILE}
			cmd cp -v /usr/share/rhel-guest-image-7/rhel-guest-image-7*.qcow2  /tmp/ 2>&1 | tee -a ${LOGFILE}
		else
			cmd cp -v ${RHEL_IMAGE_URL} /tmp/${RHEL_IMAGE_NAME}.qcow2 2>&1 | tee -a ${LOGFILE}
		fi
		cmd systemctl restart libvirtd
		cmd virt-customize -a /tmp/${RHEL_IMAGE_NAME}.qcow2 --root-password password:${PASSWORD} 2>&1 | tee -a ${LOGFILE}
		cmd glance image-create \
			 --name ${RHEL_IMAGE_NAME} \
			 ${IMAGE_IS_PUBLIC_OPTION} \
			 --disk-format qcow2 \
			 --container-format bare \
			 --progress \
			 --file /tmp/${RHEL_IMAGE_NAME}.qcow2
	fi
	RHEL_IMAGE_ID=$(glance image-list | grep ${RHEL_IMAGE_NAME} | awk ' {print $2} ')
  cmd glance image-show ${RHEL_IMAGE_ID} 2>&1 | tee -a ${LOGFILE}

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

  if ! neutron security-group-rule-list | grep "22/tcp"
	then
		cmd neutron security-group-rule-create \
			  --protocol tcp \
			  --port-range-min 22 \
			  --port-range-max 22 \
			  --direction ingress \
			  default
	fi

}

build-instances() {
	cmd echo "INFO: Starting function 'build-instances'"
	source ~/keystonerc_${USERNAME}
	glance image-list
	if nova list | grep cirros-test
	then
		nova delete cirros-test
		sleep 5
	fi
  cmd openstack volume create --size 1 cirros-vol-test
  CIRROS_VOL_ID=$(openstack volume list -f value -c ID -c "Display Name" | awk '/cirros-vol-test/ { print $1 }')
	cmd nova boot cirros-test \
    --flavor 1 \
    --poll \
    --key-name ${USERNAME} \
    --image ${CIRROS_IMAGE_ID} \
    --block-device source=volume,id=${CIRROS_VOL_ID},dest=volume,shutdown=remove

	if nova list | grep rhel-test
	then
		nova delete rhel-test
		sleep 5
	fi
  cmd openstack volume create --size 10 rhel-vol-test
  RHEL_VOL_ID=$(openstack volume list -f value -c ID -c "Display Name" | awk '/rhel-vol-test/ { print $1 }')
	cmd nova boot rhel-test \
    --flavor 2 \
    --key-name ${USERNAME} \
    --image ${RHEL_IMAGE_ID} \
    --poll \
    --block-device source=volume,id=${RHEL_VOL_ID},dest=volume,shutdown=remove

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
    elif [ $counter -gt $TIMEOUT_WARN ]
    then
      echo WARN: this is taking longer than expected
    fi
	done
	echo ""
}

verify-networking() {
	source /root/keystonerc_${USERNAME}
	nova list
	# Get a VNC console
	cmd nova get-vnc-console cirros-test novnc
	cmd nova get-vnc-console rhel-test novnc

	# Grab the instance ID
	CIRROS_INSTANCE_ID=$(nova list | awk '/cirros-test/ {print $2}')
	RHEL_INSTANCE_ID=$(nova list | awk '/rhel-test/ {print $2}')

	# Grab the IP to ping it after instance boot
	CIRROS_IP=$( openstack server list -f value -c Name -c Networks | awk -F= ' /cirros-test/ { print $2 }')
	RHEL_IP=$( openstack server list -f value -c Name -c Networks | awk -F= ' /rhel-test/ { print $2 }')
	echo -n "Waiting for instance networking to be available"
    counter=0
	while :
	do
    counter=$(( $counter + 1 ))
		echo -n "."
		sleep 1
		if ping -c 2 ${CIRROS_IP} 2>&1 > /dev/null && ping -c 2 ${RHEL_IP} 2>&1 > /dev/null
    then
      break
    fi
    if [ $counter -gt $TIMEOUT ]
    then
      echo ERROR: something went wrong - check console
      exit 1
    elif [ $counter -gt $TIMEOUT_WARN ]
    then
      echo WARN: this is taking longer than expected
    fi
	done
	echo ""

	# Ping the IP
	echo "INFO: Pinging IP for Cirros instance: ${CIRROS_IP}"
	cmd ping -c 3 ${CIRROS_IP}
	sleep 10
	echo "INFO: Pinging IP for RHEL instance: ${RHEL_IP}"
	cmd ping -c 3 ${RHEL_IP}

	# Get a VNC consolE
	source /root/keystonerc_${USERNAME}
}

cleanup () {
  source /root/keystonerc_${USERNAME}
  cmd openstack server delete cirros-test
  #cmd openstack server delete rhel-test
}

# Main
prep 2>&1 | tee -a ${LOGFILE}
packstack-install 2>&1 | tee -a ${LOGFILE}
# For some reason calling this from a function causes packstack to hang on copying puppet modules
cmd packstack --answer-file=/root/openstack-scripts/answers.txt
post-install-config 2>&1 | tee -a ${LOGFILE}
post-install-admin-tasks 2>&1 | tee -a ${LOGFILE}
# Image creation can't be redirected to a log file or the --progress option doesn't work
create-images
post-install-user-tasks 2>&1 | tee -a ${LOGFILE}
build-instances 2>&1 | tee -a ${LOGFILE}
source /root/keystonerc_${USERNAME}
if nova list | grep ERROR
then
  echo "ERROR: Something went wrong, check virt capabilities of this host ..."
  exit 1
fi
verify-networking 2>&1 | tee -a ${LOGFILE}
cleanup 2>&1 | tee -a ${LOGFILE}

echo "INFO: All functions completed" 2>&1 | tee -a ${LOGFILE}

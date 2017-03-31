# Setup KVM and OpenStack

These scripts configure a RHEL 7.3 bare-metal host to be a KVM hypervisor. It then creates a KVM VM with a static configuration and installs OpenStack in an all-in-one configuration. Then configures a user, project, uploads images, boots instances and creates a volume to ensure everything is working.

The end result is for the RH Summit L104353 lab. The intention is to run OpenShift instances on top of it.

## Assumptions
* The bare-metal KVM host is internal on Red Hat's VPN
* The host does not have any subscriptions
* rhos-release will be used to provide RHEL 7.3 and OSP repos
* Nested virt should be enabled on the host
* A new libvirt network will be created 172.20.17.0/24
** This network does not have DHCP enabled, since OSp will provide that
** Feel free to add additional KVM VMs on this network, but understand that the reserved pool for OSP is 172.20.27.100 - .200
* The default network is still used on the OSP VM, but only for SSH into it
* The OSP environment is set up to use a flat network, no floating IPs.
* Use the user1 user, not admin to create instances

## Use
On the bare-metal host, simply run
```
# ./host-kvm-setup.sh
```

To start over and cleanup a previous run, execute:
```
# ./remove-host-kvm-setup.sh
```

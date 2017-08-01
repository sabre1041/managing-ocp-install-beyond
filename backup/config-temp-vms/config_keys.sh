#!/bin/bash

for i in master-clone.e2e.bos.redhat.com node-1-clone.e2e.bos.redhat.com node-2-clone.e2e.bos.redhat.com; do
	ssh-copy-id -i ~/.ssh/id_rsa $i
done


#!/bin/bash

# Enter any commands needed to prep your host specific to your lab environment

# Using internal rhos-release so no dependency on Satellite or Hosted
if ! rpm -q rhos-release
then
  cmd yum -y install http://rhos-release.virt.bos.redhat.com/repos/rhos-release/rhos-release-latest.noarch.rpm
fi
cmd rhos-release rhel-7.3

# Disable irrelevant repos
OLD_REPOS="core-0 core-1 core-2 rhelosp-rhel-7.2-extras rhelosp-rhel-7.2-ha rhelosp-rhel-7.2-server rhelosp-rhel-7.2-z rhelosp-rhel-7.3-ha rhelosp-rhel-7.3-pre-release"
REPOS_TO_DISABLE=""
REPOS_ENABLED=$(yum repolist)
for repo in ${OLD_REPOS}
do
  if echo ${REPOS_ENABLED} | grep ${repo}
  then
    REPOS_TO_DISABLE+="${REPOS_TO_DISABLE} --disable ${repo}"
  fi
done
if [ ! -z "${REPOS_TO_DISABLE}" ]
then
  cmd yum-config-manager ${REPOS_TO_DISABLE}
fi

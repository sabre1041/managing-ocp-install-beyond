#!/bin/bash

# MIT License
#
# Copyright (c) 2018 Miguel Pérez Colino <miguel@redhat.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

#
# Helper script to prepare Ansible Tower to deploy OpenShift Container Platform
# on AWS
#

set -euo pipefail

# Directory of this script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Our config file
SECRETS_FILE='./my_secrets.yml'

# Assign log file for ansible
LOGS_DIR="${DIR}/logs/"
if [ ! -d ${LOGS_DIR} ]; then
  mkdir -p ${LOGS_DIR}
fi
ANSIBLE_LOG_PATH="${LOGS_DIR}/ansible-$(date +%F_%T).log"
export ANSIBLE_LOG_PATH

function display_help {
  echo "./$(basename "$0") [ -s | --secrets FILE ] [ -q | --quiet ] [ -h | --help | --vpc-keypair | --lab | --teardown | --redeploy | --clear-logs ] [ OPTIONAL ANSIBLE OPTIONS ]

Helper script to deploy infrastructure and OpenShift on Google Cloud Platform

Where:
  -s | --secrets FILE  Provide custom config file, must be relative
                      to the 'ansible' directory. Default is '../config.yaml'
  -q | --quiet        Don't ask for confirmations
  -h | --help         Display this help text
  --vpc-keypair       Create VPC and Keypair (prereq to launch the lab)
  --lab               Deply lab infrastructure: Tower, OpenShift
  --teardown          Teardown Tower, OpenShift and the infrastructure.
                      Warning: you will loose all your data
  --redeploy          Teardown Tower, OpenShift, theinfrastructure and deploy
                      it again. Warning: you will loose all your data
  --clear-logs        Delete all Ansible logs created by this script

If no action option is specified, the script will create the infrastructure
and deploy OpenShift on top of it.

OPTIONAL ANSIBLE OPTIONS  All other options following the options mentioned
                          above will be passed directly to the Ansible. For
                          example, you can override any Ansible variable with:
                          ./$(basename "$0") -e openshift_debug_level=4"
}

# Ask user for confirmation. First parameter is message
function ask_for_confirmation {
  if [ $QUIET -eq 1 ]; then
    return 0
  fi
  read -p "${1} [y/N] " yn
  case $yn in
    [Yy]* )
      return 0
      ;;
    * )
      exit 1
      ;;
  esac
}

# Run given playbook (1. param). All other parameters
# are passed directly to Ansible.
function run_playbook {
  playbook="$1"
  shift
  pushd "${DIR}"
  ansible-playbook -e "@${SECRETS_FILE}" $@ "$playbook"
  popd
}

# Teardown infrastructure
function teardown {
  ask_for_confirmation 'Are you sure you want to destroy OpenShift and the infrastructure? You will loose all your data.'
  run_playbook aws_lab_terminate.yml "$@"
}

# Creates VPC and Keypair
function vpc-keypair {
  echo "AWS VPC and Keypair setup"
  run_playbook aws_vpc_keypair.yml "-vvv $@"
  echo "---   Update subnet-id in $ECRETS_FILE   ---"
}

# Main function which creates infrastructure and deploys OCP
function lab {
  echo "Lab Launch"
  run_playbook aws_lab_launch.yml "$@"
}

while true; do
  case ${1:-} in
    -s | --secrets )
      shift
      SECRETS_FILE="${1}"
      shift
      ;;
    -q | --quiet )
      QUIET=1
      shift
      ;;
    -h | --help )
      display_help
      exit 0
      ;;
    --lab )
      shift
      lab "$@"
      exit 0
      ;;
    --vpc-keypair )
      shift
      vpc-keypair "$@"
      exit 0
      ;;
    --teardown )
      shift
      teardown "$@"
      exit 0
      ;;
    --redeploy )
      shift
      teardown "$@"
      main "$@"
      exit 0
      ;;
    --clear-logs )
      rm -f "${LOGS_DIR}"/ansible-*.log
      exit 0
      ;;
    * )
      display_help
      exit 0
      ;;
  esac
done

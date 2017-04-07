#!/bin/bash

source group_vars_all

prep_vm REPO

deploy_vm REPO 4096 1

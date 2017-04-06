#!/bin/bash

source group_vars_all

prep_vm TOWER

deploy_vm TOWER 8192 4

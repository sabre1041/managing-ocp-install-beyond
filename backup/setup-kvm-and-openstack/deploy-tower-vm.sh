#!/bin/bash

source group_vars_all

prep_vm tower

customize_vm tower

deploy_vm tower

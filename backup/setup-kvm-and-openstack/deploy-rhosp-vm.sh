#!/bin/bash

source group_vars_all

prep_vm rhosp

customize_vm rhosp

deploy_vm rhosp

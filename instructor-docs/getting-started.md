# Instructor Setup of "Managing OpenShift from Installation and Beyond"

Last update: May 14th, 2018

## Related Projects

https://github.com/scollier/ansible-ami-builder

## General Overview

This is a guide for instructors to show how to set up the lab for students. More detail will be provided in subsequent chapters.

1. Provision the VPC and the private keys that are used to log into the AWS instances.
2. Build the AMIs: http, OCP, Tower.
3. Launch the AMI for however many students are needed.
4. Have the students start the lab.

## Prerequisites

* Ansible >= 2.4
* AWS account with keys / permissions to make API calls
* AWS private key to log into instances
* AWS route53 managed DNS zone
* RHN username and password with access to the proper channels
* List of pools that have access to the proper channels
* Secrets file to store keys, passwords, etc.
* Tower evaluation license

## Preparing the AWS Environment

1. First you need to clone this repository

```git clone https://github.com/sabre1041/managing-ocp-install-beyond```

2. Configure the `secrets.yml` file that is in the root directory of the repo with your environment configuration. That file is an example, substitute the appropriate parameters. The sections of the `secrets.yml` file have been laid out for you:

* Access keys
* General parameters
* AWS Instance sizes
* AWS location information
* AMI configuration
* Tower machine credentials
* Tower access keys
* Tower machine credentials


3. Deploy the AWS VPC and private key. Change into the "Managing OCP From Installation and Beyond" directory and run the command from there.

```ansible-playbook -vvv -e @secrets.yml aws_vpc_keypair.yml```

That will create a file in your local directory for the private key called: `./aws-private.pem`.

You will also need to configure one thing manually on the VPC subnet.  Go to the AWS console and go to the VPC Dashboard, select the subnet that was created, right click on that subnet and enable `Public DNS` names.

## Build your AMIs

You will need to build the following AMIs:
* OpenShift Container Platform
* Ansible Tower
* Instructor (Optional)

The instructor VM is used to share the private key to students.  If you have another way to share it more securely, please do so.

To build the AMIs, refer to the "Related Projects" repo above. and follow the [docs](https://github.com/scollier/ansible-ami-builder/blob/master/docs/getting-started.md) listed there.

Once the AMIs have been built, add those to your `secrets.yml` file in the `AMI Configuration` section.  You will only need the `OCP` and the `Tower` AMIs for this, right now.

## Launch the lab

Now that you have configured AWS with a VPC and a private key, and built out your AMIs, the next step is to launch the lab. The important parts of the `secrets.yml` file are:

```
tower_password: "changePassword"
tower_config: self
lab_user: summit
student_count: 15
```

The defaults can be taken, except for the student count. If you are new to the lab, start out with a count of 1 or 2 to see how VMs are being launched.  You can also customize the `lab_user` parameter so that you can recoginze which instances you are working on.  But in general, that needs to be called "student".

## Share the Private Key

As mentioned before, you can either host the private key on a web server running in AWS, or somewhere else.  I recommend taking this step pretty seriously as this will provide permissions to log into your VMs running in AWS.





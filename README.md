# MAAS Auto-builder

This is a quick-and-dirty set of shell scripts that will build out and
bootstrap a MAAS environment with all of the bits and pieces you need to get
it running for any cloud, any workload.

* `manage-vm-nodes.sh.........`: Create kvm instances that MAAS will manage
* `manage-hypervisor-nodes.sh.`: Create hypervisors that MAAS will manage
* `bootstrap-maas.sh..........`: Build and bootstrap your MAAS environment
* `functions.sh...............`: Common function that the first 2 scripts use
* `user-data.yaml.............`: cloud-init for hypervisor nodes

There are plenty of options to customize its behavior, as well as drop in to
any step of the process without rebuilding the full MAAS from scratch.

## Requirements

Requires, minimally, `bash`, `jq` and a working Ubuntu environment (see 
below for a custom example setup). This has **not** been tested on CentOS 
or Debian, but should work minimally on those environments, if you choose 
to make that your host.  Patches are welcome, of course.

## Components - bootstrap-maas.sh

```
  -a <cloud_name>    Do EVERYTHING (maas, juju cloud, juju bootstrap)
  -b                 Build out and bootstrap a new MAAS
  -c <cloud_name>    Add a new cloud + credentials
  -i                 Just install the dependencies and exit
  -j <name>          Bootstrap the Juju controller called <name>
  -n                 Create MAAS kvm nodes (to be imported into chassis)
  -r                 Remove the entire MAAS server + dependencies
  -t <cloud_name>    Tear down the cloud named <cloud_name>
```

## Components - manage-hypervisor-nodes.sh

```
  -a <node>   Create and Deploy
  -c <node>   Creates Hypervisor
  -d <node>   Deploy Hypervisor
  -k <node>   Add Hypervisor as Pod
  -n <node>   Assign Networks
  -p <node>   Update Partitioning
  -w <node>   Removes Hypervisor
```

## Components - manage-maas-nodes.sh

```
  -c    Creates everything
  -w    Removes everything
  -d    Releases VMs, Clears Disk
  -n    Updates all the networks on all VMs
  -r    Recommission all VMs
  -j    Only create juju VM
  -z    Adds the machines to their respective zones
```

## Misc - functions.sh

Many functions that are common between the 2 scripts above

## Misc - user-data.yaml

`cloud-init` file, that helps with deployment of the hypervisors. This helps
to automate the deployment of the hypervisor, which in turns grabs this repo
and deploys all the VMs required.

## Installing and testing MAAS

Just run `./bootstrap-maas.sh` with the appropriate option above.
Minimally, you'll want to use `./bootstrap-maas.sh -b` or `-i` to install
just the components needed.

I've done all the work needed to make this as idempotent as possible.  It
will need some minor tweaks to get working with MAAS 2.4.x, because of the
newer PostgreSQL dependencies.

## Example setup

```
host------------------
                      \
                       home router
                      / 
maas VM --- laptop ---

```

Qemu/KVM instance using a custom bridge network to ensure that the DHCP
requests from the host to be managed by MaaS can be captured by the VM.

### Bridge network setup

https://levelup.gitconnected.com/how-to-setup-bridge-networking-with-kvm-on-ubuntu-20-04-9c560b3e3991

### Other helpful resources:

https://www.cyberciti.biz/faq/how-to-reset-forgotten-root-password-for-linux-kvm-qcow2-image-vm/
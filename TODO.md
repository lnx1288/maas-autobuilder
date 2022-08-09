# Todo

1. ~~add the hypervisor as a flag rather then the configuration file when adding
   hypervisors.~~
1. ~~Add script to cloud-init, that will allow to wipe disk. This will allow to
   reboot the hypervisor, such that we don't have to log back in after the
   machine has been re-commissioned.~~
1. ~~Update hypervisor config such that it works with focal~~
1. Add the ability to add multiple storage pools (1 x SSD, 1 x HDD)
1. ~~Update `boostrap-maas.sh`~~
   1. ~~Snap implementation~~
   1. ~~Adding VLANs and subnets~~
   1. ~~Adding spaces~~
* bootstrap-maas.sh cannot be executed by root or it will fail, solve it
* if snapd is not installed bootstrap-maas.sh fails, solve that 


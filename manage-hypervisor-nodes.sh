#!/bin/bash

# set -x
. functions.sh

# Time between building VMs
build_fanout=60

# Adds all the subnets, vlans and therefore bridges to the hypervisor, all
# based on the configuration from hypervisor.config and/or default.config
maas_assign_networks()
{
    system_id=$1

    # Get the details of the physical interface
    phsy_int=$(maas ${maas_profile} interfaces read ${system_id} | jq ".[] | {id:.id, name:.name,parent:.parents}" --compact-output | grep "parent.*\[\]")
    phys_int_name=$(echo $phsy_int | jq .name | sed s/\"//g)
    phys_int_id=$(echo $phsy_int | jq .id | sed s/\"//g)

    i=0
    for vlan in ${vlans[*]}
    do
        subnet_line=$(maas admin subnets read | jq ".[] | {subnet_id:.id, vlan:.vlan.vid, vlan_id:.vlan.id}" --compact-output | grep "vlan\":$vlan,")
        maas_vlan_id=$(echo $subnet_line | jq .vlan_id | sed s/\"//g)
        maas_subnet_id=$(echo $subnet_line | jq .subnet_id | sed s/\"//g)
        ip_addr=""
        if [[ $i -eq 0 ]] ; then
            # Set the first interface to be static as per the configuration so that it
            # consistent over re-provisioning of the system
            vlan_int_id=${phys_int_id}
            mode="STATIC"
            ip_addr="ip_address=$hypervisor_ip"
        else
            vlan_int=$(maas ${maas_profile} interfaces create-vlan ${system_id} vlan=${maas_vlan_id} parent=$phys_int_id)
            vlan_int_id=$(echo $vlan_int | jq .id | sed s/\"//g)
            if [[ $vlan -eq $external_vlan ]] ; then
		# Set the external IP to be static as per the configuration
                mode="STATIC"
                ip_addr="ip_address=$external_ip"
            else
                # Set everything else to be auto assigned
                mode="AUTO"
            fi
        fi
        bridge_int=$(maas ${maas_profile} interfaces create-bridge ${system_id} name=${bridges[$i]} vlan=$maas_vlan_id mac_address=${hypervisor_mac} parent=$vlan_int_id)
        bridge_int_id=$(echo $bridge_int | jq .id | sed s/\"//g)
        bridge_link=$(maas ${maas_profile} interface link-subnet $system_id $bridge_int_id mode=${mode} subnet=${maas_subnet_id} ${ip_addr})
        (( i++ ))
    done
}

# Calls the functions that destroys and cleans up all the VMs
wipe_node() {
    install_deps
    maas_login
    destroy_node
}

create_node() {
    install_deps
    maas_login
    maas_add_node ${hypervisor_name} ${hypervisor_mac} physical
}

install_node() {
    install_deps
    maas_login
    deploy_node
}

# The purpose of this function is to stop, release the nodes and wipe the disks
destroy_node() {
    pod_id=$(maas_pod_id ${hypervisor_name})
    maas ${maas_profile} pod delete ${pod_id}

    system_id=$(maas_system_id ${hypervisor_name})
    maas ${maas_profile} machine delete ${system_id}
}

deploy_node() {
    system_id=$(maas_system_id ${hypervisor_name})
    maas ${maas_profile} machine deploy ${system_id} user_data="$(base64 user-data.yaml)"

    # Only return when the node has finised deploying
    ensure_machine_in_state ${system_id} "Deployed"
}

show_help() {
  echo "

  -c    Creates Hypervisor
  -w    Removes Hypervisor
  -d    Deploy Hypervisor
  -a    Create and Deploy
  "
}

read_config

while getopts ":cwia" opt; do
  case $opt in
    c)
        create_node
        ;;
    w)
        wipe_node
        ;;
    d)
        install_node
        ;;
    a)
        create_node
        install_node
        ;;
    \?)
        printf "Unrecognized option: -%s. Valid options are:" "$OPTARG" >&2
        show_help
        exit 1
        ;;
  esac
done

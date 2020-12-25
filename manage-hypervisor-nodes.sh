#!/bin/bash

# set -x

. default.config
. maas.config
. hypervisor.config

# how long you want to wait for commissioning
# default is 1200, i.e. 20 mins
commission_timeout=1200

# Time between building VMs
build_fanout=60

# Ensures that any dependent packages are installed for any MAAS CLI commands
# This also logs in to MAAS, and sets up the admin profile
maas_login()
{
    # Install some of the dependent packages
    sudo apt -y update && sudo apt -y install jq bc virtinst

    # We install the snap, as maas-cli is not in distributions, this ensures
    # that the package we invoke would be consistent
    sudo snap install maas --channel=2.8/stable

    # Login to MAAS using the API key and the endpoint
    echo ${maas_api_key} | maas login ${maas_profile} ${maas_endpoint} -
}

# Grabs the unique system_id for the host human readable hostname
maas_system_id()
{
    node_name=$1

    maas ${maas_profile} machines read hostname=${node_name} | jq ".[].system_id" | sed s/\"//g
}

maas_pod_id()
{
    node_name=$1

    maas ${maas_profile} pods read | jq ".[] | {pod_id:.id, hyp_name:.name}" --compact-output | \
        grep ${node_name} | jq ".pod_id" | sed s/\"//g
}


# Adds the VM into MAAS
maas_add_node()
{
    node_name=$1
    mac_addr=$2
    node_type=$3

    # This command creates the machine in MAAS. This will then automatically
    # turn the machines on, and start commissioning.
    maas ${maas_profile} machines create \
        hostname=${node_name}            \
        mac_addresses=${mac_addr}        \
        architecture=amd64/generic       \
        power_type=manual

    # Grabs the system_id for th node that we are adding
    system_id=$(maas_system_id ${node_name})

    # This will ensure that the node is ready before we start manipulating
    # other attributes.
    ensure_machine_ready ${system_id}

    # If the tag doesn't exist, then create it
    if [[ $(maas ${maas_profile} tag read ${node_type}) == "Not Found" ]] ; then
        maas ${maas_profile} tags create name=${node_type}
    fi

    # Assign the tag to the machine
    maas ${maas_profile} tag update-nodes ${node_type} add=${system_id}

    # Ensure that all the networks on the system have the Auto-Assign set
    # so that the all the of the networks on the host have an IP automatically.
    maas_assign_networks ${system_id}
}

# Attempts to auto assign all the networks for a host
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
        if [[ $i -eq 0 ]] ; then
            vlan_int_id=${phys_int_id}
            mode="STATIC"
            ip_addr="ip_address=$hypervisor_ip"
        else
	        vlan_int=$(maas ${maas_profile} interfaces create-vlan ${system_id} vlan=${maas_vlan_id} parent=$phys_int_id)
            vlan_int_id=$(echo $vlan_int | jq .id | sed s/\"//g)
            if [[ $vlan -eq $external_vlan ]] ; then
                mode="DHCP"
            else
                mode="AUTO"
            fi
            ip_addr=""
        fi
	    bridge_int=$(maas ${maas_profile} interfaces create-bridge ${system_id} name=${bridges[$i]} vlan=$maas_vlan_id mac_address=${hypervisor_mac} parent=$vlan_int_id)
        bridge_int_id=$(echo $bridge_int | jq .id | sed s/\"//g)
        bridge_link=$(maas ${maas_profile} interface link-subnet $system_id $bridge_int_id mode=${mode} subnet=${maas_subnet_id} ${ip_addr})
        (( i++ ))
    done
}

# This takes the system_id, and ensures that the machine is uin Ready state
# You may want to tweak the commission_timeout above in somehow it's failing
# and needs to be done quicker
ensure_machine_ready()
{
    system_id=$1

    time_start=$(date +%s)
    time_end=${time_start}
    status_name=$(maas ${maas_profile} machine read ${system_id} | jq ".status_name" | sed s/\"//g)
    while [[ ${status_name} != "Ready" ]] && [[ $( echo ${time_end} - ${time_start} | bc ) -le ${commission_timeout} ]]
    do
        sleep 20
        status_name=$(maas ${maas_profile} machine read ${system_id} | jq ".status_name" | sed s/\"//g)
        time_end=$(date +%s)
    done
}

# Calls the functions that destroys and cleans up all the VMs
wipe_node() {
    maas_login
    destroy_node
}

create_node() {
    maas_login
    maas_add_node ${hypervisor_name} ${hypervisor_mac} physical
}

install_node() {
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
    #maas ${maas_profile} machine deploy ${system_id} install_kvm=true user_data="$(base64 user-data.yaml)"

    maas ${maas_profile} machine deploy ${system_id} user_data="$(base64 user-data.yaml)"

    # TODO: keep trying, until it gives a valid output
    #until $(maas ${maas_profile} machine deploy ${system_id} install_kvm=true) ; do
    #    machine ${maas_profile} machine release ${system_id}
}

show_help() {
  echo "

  -c    Creates Hypervisor
  -w    Removes Hypervisor
  -i    Install/Deploy Hypervisor
  -a    Create and Deploy
  "
}

while getopts ":cwdi" opt; do
  case $opt in
    c)
        create_node
        ;;
    w)
        wipe_node
        ;;
    i)
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

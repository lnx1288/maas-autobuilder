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
        subnet_line=$(maas admin subnets read | jq ".[] | {subnet_id:.id, vlan:.vlan.vid, vlan_id:.vlan.id}" --compact-output | grep "vlan\":$vlan," | head -n 1)
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

maas_create_partitions()
{
    system_id=$1

    size=20

    actual_size=$(( $size * 1024 * 1024 * 1024 ))

    storage_layout=$(maas ${maas_profile} machine set-storage-layout ${system_id} storage_layout=lvm vg_name=${hypervisor_name} lv_name=root lv_size=${actual_size})

    vg_device=$(echo $storage_layout | jq ".volume_groups[].id" )
    remaining_space=$(maas ${maas_profile} volume-group read ${system_id} ${vg_device} | jq ".available_size" | sed s/\"//g)

    libvirt_lv=$(maas ${maas_profile} volume-group create-logical-volume ${system_id} ${vg_device} name=libvirt size=${remaining_space})
    libvirt_block_id=$(echo ${libvirt_lv} | jq .id)

    stg_fs=$(maas ${maas_profile} block-device format ${system_id} ${libvirt_block_id} fstype=ext4)
    stg_mount=$(maas ${maas_profile} block-device mount ${system_id} ${libvirt_block_id} mount_point=${storage_path})
}

maas_add_pod()
{
    pod_create=$(maas ${maas_profile} pods create power_address="qemu+ssh://${virsh_user}@${hypervisor_ip}/system" power_user="${virsh_user}" power_pass="${qemu_password}" type="virsh")
    pod_id=$(echo $pod_create | jq ".id" | sed s/\"//g)
    pod_name=$(maas ${maas_profile} pod update ${pod_id} name=${hypervisor_name})
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
    #maas_add_pod
}

add_pod()
{
    install_deps
    maas_login
    maas_add_pod
}

# Fixes all the networks on all the VMs
network_auto()
{
    install_deps
    maas_login

    system_id=$(maas_system_id ${hypervisor_name})
    maas_assign_networks ${system_id}
}

# Fixes all the networks on all the VMs
create_partitions()
{
    install_deps
    maas_login

    system_id=$(maas_system_id ${hypervisor_name})
    maas_create_partitions ${system_id}
}

# The purpose of this function is to stop, release the nodes and wipe the disks
destroy_node() {
    pod_id=$(maas_pod_id ${hypervisor_name})
    pod_delete=$(maas ${maas_profile} pod delete ${pod_id})

    system_id=$(maas_system_id ${hypervisor_name})
    machine_delete=$(maas ${maas_profile} machine delete ${system_id})
}

deploy_node() {
    system_id=$(maas_system_id ${hypervisor_name})
    maas ${maas_profile} machine deploy ${system_id} user_data="$(base64 user-data.yaml)" > /dev/null

    # Only return when the node has finised deploying
    ensure_machine_in_state ${system_id} "Deployed"
}

show_help() {
  echo "

  -a    Create and Deploy
  -c    Creates Hypervisor
  -d    Deploy Hypervisor
  -k    Add Hypervisor as Pod
  -n    Assign Networks
  -p    Update Partitioning
  -w    Removes Hypervisor
  "
}

read_config

while getopts ":cwdaknp" opt; do
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
    k)
        add_pod
        ;;
    n)
        network_auto
        ;;
    p)
        create_partitions
        ;;
    \?)
        printf "Unrecognized option: -%s. Valid options are:" "$OPTARG" >&2
        show_help
        exit 1
        ;;
  esac
done

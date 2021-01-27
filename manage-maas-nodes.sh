#!/bin/bash

# set -x
. functions.sh

# Storage type
storage_format="raw"

# Models for nic and storage
nic_model="virtio"
stg_bus="scsi"

# Time between building VMs
build_fanout=60

maas_assign_networks()
{
    maas_auto_assign_networks $1
}

# Attempts to auto assign all the networks for a host
# Note: This only works straight after a commissioning of a machine
maas_auto_assign_networks()
{
    system_id=$1

    # Grabs all the interfaces that are attached to the system
    node_interfaces=$(maas ${maas_profile} interfaces read ${system_id} \
        | jq ".[] | {id:.id, name:.name, mode:.links[].mode, subnet:.links[].subnet.id, vlan:.vlan.vid }" --compact-output)

    # This for loop will go through all the interfaces and enable Auto-Assign
    # on all ports
    for interface in ${node_interfaces}
    do
        int_id=$(echo $interface | jq ".id" | sed s/\"//g)
        subnet_id=$(echo $interface | jq ".subnet" | sed s/\"//g)
        mode=$(echo $interface | jq ".mode" | sed s/\"//g)
        vlan=$(echo $interface | jq ".vlan" | sed s/\"//g)

        # Although the vlan would have been set the discovered vlan wouldn't,
        # and therefore link[] and discovery[] list won't exist. So we grab
        # the subnet details from subnets that have the vlan assigned/discovered
        # at commissioning stage
        if [[ $subnet_id == null ]] ; then
            subnet_line=$(maas admin subnets read | jq ".[] | {subnet_id:.id, vlan:.vlan.vid, vlan_id:.vlan.id}" --compact-output | grep "vlan\":$vlan,")
            subnet_id=$(echo $subnet_line | jq .subnet_id | sed s/\"//g)
        fi
        # If vlan is the external network, then we want to grab IP via DHCP
        # from the external network. Other networks would be auto mode
        if [[ $vlan -eq $external_vlan ]] && [[ $mode != "dhcp" ]]; then
            new_mode="DHCP"
        elif [[ $mode != "auto" ]] && [[ $mode != "dhcp" ]] ; then
            new_mode="AUTO"
        fi

        # Then finally set link details for all the interfaces that haven't
        # been configured already
        if [[ $new_mode != "AUTO" ]] || [[ $new_mode != "DHCP" ]]; then
            assign_network=$(maas ${maas_profile} interface link-subnet ${system_id} ${int_id} mode=${new_mode} subnet=${subnet_id})
        fi
    done
}

# Calls the 3 functions that creates the VMs
create_vms() {
    install_deps
    maas_login
    create_storage
    build_vms
}

# Calls the 3 functions that creates the VMs
create_juju() {
    install_deps
    maas_login
    create_storage "juju"
    build_vms "juju"
}

# Calls the functions that destroys and cleans up all the VMs
wipe_vms() {
    install_deps
    maas_login
    destroy_vms
}

# Fixes all the networks on all the VMs
do_nodes()
{
    install_deps
    maas_login

    function=$1

    juju_total=1

    for ((virt="$node_start"; virt<=node_count; virt++)); do
        node_type="compute"
        if [[ $virt -le $control_count ]] ; then
            node_type="control"
        fi
        if [[ $juju_total -le $juju_count ]] ; then
            printf -v virt_node %s-%02d "$hypervisor_name-juju" "$juju_total"

            doing_juju="true"
	    node_type="juju"
            (( virt-- ))
            (( juju_total++ ))
	else
            printf -v virt_node %s-%02d "$compute" "$virt"
	fi
        system_id=$(maas_system_id ${virt_node})


        if [[ $function == "network" ]] ; then
            maas_auto_assign_networks ${system_id} &
        elif [[ $function == "zone" ]] ; then
            machine_set_zone ${system_id} ${hypervisor_name} &
        elif [[ $function == "commission" ]] ; then
            commission_node ${system_id} &
            sleep ${build_fanout}
	elif [[ $function == "tag" ]] ; then
            machine_add_tag ${system_id} ${node_type}
        fi
    done
    wait
}

# Creates the disks for all the nodes
create_storage() {
    # To keep a track of how many juju VMs we have created
    only_juju="false"
    node_count_bak=$node_count
    if [[ $1 == "juju" ]] ; then
        node_count=0
        if [[ $juju_count -lt 1 ]] ; then
            echo "WARNING: requested only create juju, but juju_count = ${juju_count}"
            return 0
        fi
    fi
    for ((virt="$node_start"; virt<=node_count; virt++)); do
        printf -v virt_node %s-%02d "$compute" "$virt"

        # Create th directory where the storage files will be located
        mkdir -p "$storage_path/$virt_node"

        # For all the disks that are defined in the array, create a disk
        for ((disk=0;disk<${#disks[@]};disk++)); do
            file_name="$storage_path/$virt_node/$virt_node-d$((${disk} + 1)).img"

            if [[ ! -f $file_name ]] ; then
                /usr/bin/qemu-img create -f "$storage_format" "${file_name}" "${disks[$disk]}"G &
            fi
        done
    done
    for ((juju=1; juju<=juju_count; juju++)); do
        printf -v virt_node %s-%02d "$hypervisor_name-juju" "$juju"

        # Create th directory where the storage files will be located
        mkdir -p "$storage_path/$virt_node"

        file_name="$storage_path/$virt_node/$virt_node.img"

        if [[ ! -f $file_name ]] ; then
            /usr/bin/qemu-img create -f "$storage_format" ${file_name} "${juju_disk}"G &
        fi
    done
    node_count=$node_count_bak
    wait
}

# The purpose of this function is to stop, release the nodes and wipe the disks
# to save space, and then so that the machines in MAAS can be re-used
wipe_disks() {
    juju_total=1
    doing_juju="false"
    for ((virt="$node_start"; virt<=node_count; virt++)); do
        if [[ $juju_total -le $juju_count ]] ; then
            printf -v virt_node %s-%02d "$hypervisor_name-juju" "$juju_total"
            doing_juju="true"
            (( virt-- ))
            (( juju_total++ ))
        else
            printf -v virt_node %s-%02d "$compute" "$virt"
            doing_juju="false"
        fi

        system_id=$(maas_system_id ${virt_node})

        # Release the machine in MAAS
        release_machine=$(maas ${maas_profile} machine release ${system_id})

        # Ensure that the machine is in ready state before the next step
        ensure_machine_in_state ${system_id} "Ready"

        # Stop the machine if it is running
        # It's probably stopped anyway as per the release above
        virsh --connect qemu:///system shutdown "$virt_node"

        # Remove the disks
        if [[ $doing_juju == "true" ]] ; then
            rm -rf "$storage_path/$virt_node/$virt_node.img"
        else
            for ((disk=0;disk<${#disks[@]};disk++)); do
                rm -rf "$storage_path/$virt_node/$virt_node-d$((${disk} + 1)).img" &
            done
        fi
    done
    # Re-create the storage again from scratch
    create_storage
    wait
}

machine_exists()
{
    node_name=$1

    virsh_machine=$(virsh list --all --name | grep ${node_name})

    if [[ $virsh_machine != "" ]] ; then
        macaddr=$(virsh domiflist ${node_name} | grep br0 | awk '{print $5}')

        echo $macaddr
    else
        echo "false"
    fi

}

# Builds the VMs from scratch, and then adds them to MAAS
build_vms() {
    # To keep a track of how many juju VMs we have created
    juju_total=1
    only_juju="false"
    if [[ $1 == "juju" ]] ; then
        only_juju="true"
        if [[ $juju_count -lt 1 ]] ; then
            echo "WARNING: requested only create juju, but juju_count = ${juju_count}"
            return 0
        fi
    fi

    for ((virt="$node_start"; virt<=node_count; virt++)); do

        # Based on the bridges array, it will generate these amount of MAC
        # addresses and then create the network definitions to add to
        # virt-install
        macaddr=()
        network_spec=""
        extra_args=""

        # Based on the type of network we are using we will assign variables
        # such that this can be either bridge or network type
        if [[ $network_type == "bridge" ]] ; then
            net_prefix="bridge"
            net_type=(${bridges[@]})
        elif [[ $network_type == "network" ]] ; then
            net_prefix="network"
            net_type=(${networks[@]})
        fi

        # Now define the network definition
        for ((mac=0;mac<${#net_type[@]};mac++)); do
            macaddr+=($(printf '52:54:00:%02x:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))" "$((RANDOM%256))"))
            network_spec+=" --network=$net_prefix="${net_type[$mac]}",mac="${macaddr[$mac]}",model=$nic_model"
        done

        if [[ $juju_total -le $juju_count ]] ; then
            printf -v virt_node %s-%02d "$hypervisor_name-juju" "$juju_total"

            ram="$juju_ram"
            vcpus="$juju_cpus"
            node_type="juju"

            network_spec="--network=$net_prefix="${net_type[0]}",mac="${macaddr[0]}",model=$nic_model"

            disk_spec="--disk path=$storage_path/$virt_node/$virt_node.img"
            disk_spec+=",format=$storage_format,size=${juju_disk},bus=$stg_bus,io=native,cache=directsync"

            # So that we have the right amount of VMs
            (( virt-- ))
            (( juju_total++ ))
            # This will ensure that we only create the juju VMs
            [[ $only_juju == "true" ]] && [[ $juju_total -gt $juju_count ]] && virt=$(( $node_count + 1 ))
        else
            printf -v virt_node %s-%02d "$compute" "$virt"
            # Based on the variables in hypervisor.config, we define the variables
            # for ram and cpus. This also allows a number of control nodes that
            # can be defined as part of full set of nodes.
            ram="$node_ram"
            vcpus="$node_cpus"
            node_type="compute"
            if [[ $virt -le $control_count ]] ; then
                ram="$control_ram"
                vcpus="$control_cpus"
                node_type="control"
            fi

            # Based on the disks array, it will create a definition to add these
            # disks to the VM
            disk_spec=""
            for ((disk=0;disk<${#disks[@]};disk++)); do
                disk_spec+=" --disk path=$storage_path/$virt_node/$virt_node-d$((${disk} + 1)).img"
                disk_spec+=",format=$storage_format,size=${disks[$disk]},bus=$stg_bus,io=native,cache=directsync"
            done
        fi

        # Check to see if the libvirt machine already exists. If it exists
        # then just use the same one again and commission in MAAS
        check_machine=$(machine_exists ${virt_node})
        if [[ $check_machine != "false" ]] ; then
            macaddr=$check_machine

            maas_add_node ${virt_node} ${macaddr} ${node_type} &

            sleep ${build_fanout}
            continue
        fi

        # For testing and WIP/POC
        if [[ ${enable_secureboot} == "true" ]] ; then
            extra_args+=" --boot loader_secure=yes"
            #extra_args+=",loader=/usr/share/OVMF/OVMF_CODE.secboot.fd"
            #extra_args+=",nvram_template=/usr/share/OVMF/OVMF_VARS.fd"
            #extra_args+=",loader_ro=yes"
            #extra_args+=",loader_type=pflash"
            extra_args+=" --machine q35"
            extra_args+=" --features smm=on"
            enable_uefi="true"
        fi

        # Flags required to enable uEFI
        [[ ${enable_uefi} == "true" ]] && extra_args+=" --boot uefi"

        # Creates the VM with all the attributes given
        virt-install -v --noautoconsole   \
            --print-xml                   \
            --autostart                   \
            --boot network,hd,menu=on     \
            --video qxl,vram=256          \
            --channel spicevmc            \
            --name "$virt_node"           \
            --ram "$ram"                  \
            --vcpus "$vcpus"              \
            --console pty,target_type=serial \
            --graphics spice,clipboard_copypaste=no,mouse_mode=client,filetransfer_enable=off \
            --cpu host-passthrough,cache.mode=passthrough  \
            --controller "$stg_bus",model=virtio-scsi,index=0  \
            $extra_args $disk_spec \
            $network_spec > "$virt_node.xml" &&

        # Create the Vm based on the XML file defined in the above command
        virsh define "$virt_node.xml"

        # Call the maas_add_node function, this will add the node to MAAS
        maas_add_node ${virt_node} ${macaddr[0]} ${node_type} &

        # Wait some time before building the next, this helps with a lot of DHCP requests
        # and ensures that all VMs are commissioned and deployed.
        sleep ${build_fanout}

    done
    wait
}

destroy_vms() {
    juju_total=1
    doing_juju="false"
    for ((virt="$node_start"; virt<=node_count; virt++)); do
        if [[ $juju_total -le $juju_count ]] ; then
            printf -v virt_node %s-%02d "$hypervisor_name-juju" "$juju_total"

            doing_juju="true"
            (( virt-- ))
            (( juju_total++ ))
        else
            printf -v virt_node %s-%02d "$compute" "$virt"
            doing_juju="false"
        fi

        # If the domain is running, this will complete, else throw a warning
        virsh --connect qemu:///system destroy "$virt_node"

        # Actually remove the VM
        virsh --connect qemu:///system undefine "$virt_node" --nvram

        # Remove the three storage volumes from disk
        if [[ $doing_juju = "true" ]] ; then
            virsh vol-delete --pool "$virt_node" "$virt_node.img"
        else
            for ((disk=0;disk<${#disks[@]};disk++)); do
                virsh vol-delete --pool "$virt_node" "$virt_node-d$((${disk} + 1)).img"
            done
        fi

        # Remove the folder storage is located
        rm -rf "$storage_path/$virt_node/"
        sync

        # Remove the XML definitions for the VM
        rm -f "$virt_node.xml" \
            "/etc/libvirt/qemu/$virt_node.xml"    \
            "/etc/libvirt/storage/$virt_node.xml" \
            "/etc/libvirt/storage/autostart/$virt_node.xml"

        # Now remove the VM from MAAS
        system_id=$(maas_system_id ${virt_node})
        delete_machine=$(maas ${maas_profile} machine delete ${system_id})
    done
}

show_help() {
  echo "

  -c    Creates everything
  -w    Removes everything
  -d    Releases VMs, Clears Disk
  -n    Updates all the networks on all VMs
  -r    Recommission all VMs
  -t    Re-tag all VMS
  -j    Only create juju VM
  "
}

# Initialise the configs
read_configs

while getopts ":cwjdnrtz" opt; do
  case $opt in
    c)
        create_vms
        ;;
    w)
        wipe_vms
        ;;
    d)
        install_deps
        maas_login
        wipe_disks
        ;;
    n)
        do_nodes network
        ;;
    r)
        do_nodes commission
        ;;
    t)
        do_nodes tag
        ;;
    j)
        create_juju
        ;;
    z)
        do_nodes zone
        ;;
    \?)
        printf "Unrecognized option: -%s. Valid options are:" "$OPTARG" >&2
        show_help
        exit 1
        ;;
  esac
done

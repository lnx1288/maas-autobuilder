#!/bin/bash

# set -x

. maas.config
. hypervisor.config

# Storage type
storage_format="raw"

# Models for nic and storage
nic_model="virtio"
stg_bus="scsi"

# how long you want to wait for commissioning
# default is 1200, i.e. 20 mins
commission_timeout=1200

# Time between building VMs
build_fanout=60

# This logs in to maas, and sets up the admin profile
maas_login()
{
	sudo apt -y update && sudo apt -y install jq bc
	sudo snap install maas --channel=2.8/stable

	echo ${maas_api_key} | maas login ${maas_profile} ${maas_endpoint} -
}

# Grabs the unique system)id for the host human readable hostname
maas_system_id()
{
	node_name=$1

	maas ${maas_profile} machines read hostname=${node_name} | jq ".[].system_id" | sed s/\"//g
}

# Adds the VM into MAAS
maas_add_node()
{
	node_name=$1
	mac_addr=$2
	node_type=$3

	maas ${maas_profile} machines create \
		hostname=${node_name} \
		mac_addresses=${mac_addr} \
		architecture=amd64/generic \
		power_type=virsh \
		power_parameters_power_id=${node_name} \
		power_parameters_power_address=${qemu_connection} \
		power_parameters_power_pass=${qemu_password}

	system_id=$(maas_system_id ${node_name})

	ensure_machine_ready ${system_id}

	# If the tag doesn't exist, then create it
	if [[ $(maas ${maas_profile} tag read ${node_type}) == "Not Found" ]] ; then
	    maas ${maas_profile} tags create name=${node_type}
	fi

	# Assign the tag to the machine
	maas ${maas_profile} tag update-nodes ${node_type} add=${system_id}

	maas_auto_assign_networks ${system_id}
}

# Attempts to auto assign all the networks for a host
maas_auto_assign_networks()
{
	system_id=$1
	node_interfaces=$(maas ${maas_profile} interfaces read ${system_id} | jq ".[] | {id:.id, name:.name, mode:.links[].mode, subnet:.links[].subnet.id }" --compact-output)
	for interface in ${node_interfaces}
	do
		int_id=$(echo $interface | jq ".id" | sed s/\"//g)
		subnet_id=$(echo $interface | jq ".subnet" | sed s/\"//g)
		mode=$(echo $interface | jq ".mode" | sed s/\"//g)
		if [[ $mode != "auto" ]] ; then
			maas ${maas_profile} interface link-subnet ${system_id} ${int_id} mode="AUTO" subnet=${subnet_id}
		fi
	done
}

create_vms() {
	maas_login
	create_storage
	build_vms
}

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

wipe_vms() {
	maas_login
	destroy_vms
}

create_storage() {
	for ((virt="$node_start"; virt<=node_count; virt++)); do
		printf -v virt_node %s-%02d "$compute" "$virt"
		mkdir -p "$storage_path/$virt_node"
		for ((disk=0;disk<${#disks[@]};disk++)); do
		    /usr/bin/qemu-img create -f "$storage_format" "$storage_path/$virt_node/$virt_node-d$((${disk} + 1)).img" "${disks[$disk]}"G &
		done
	done
	wait
}

wipe_disks() {
	for ((virt="$node_start"; virt<=node_count; virt++)); do
		printf -v virt_node %s-%02d "$compute" "$virt"
		system_id=$(maas_system_id ${virt_node})
		maas ${maas_profile} machine release ${system_id}

		ensure_machine_ready ${system_id}

		virsh --connect qemu:///system shutdown "$virt_node"

		for ((disk=0;disk<${#disks[@]};disk++)); do
			rm -rf "$storage_path/$virt_node/$virt_node-d$((${disk} + 1)).img" &
		done
	done
	create_storage
	wait
}

# Builds the VMs from scratch, and then adds them to MAAS
build_vms() {
	for ((virt="$node_start"; virt<=node_count; virt++)); do
		printf -v virt_node %s-%02d "$compute" "$virt"
		ram="$node_ram"
		vcpus="$node_cpus"
		node_type="compute"
		if [[ $virt -le $control_count ]] ; then
			ram="$control_ram"
			vcpus="$control_cpus"
			node_type="control"
		fi
		bus=$stg_bus

		macaddr=()
		network_spec=""
		for ((mac=0;mac<${#bridges[@]};mac++)); do
			macaddr+=($(printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))"))
			network_spec+=" --network=bridge="${bridges[$mac]}",mac="${macaddr[$mac]}",model=$nic_model"
		done

		disk_spec=""
		for ((disk=0;disk<${#disks[@]};disk++)); do
			disk_spec+=" --disk path=$storage_path/$virt_node/$virt_node-d$((${disk} + 1)).img"
			disk_spec+=",format=$storage_format,size=${disks[$disk]},bus=$bus,io=native,cache=directsync"
		done

		virt-install -v --noautoconsole   \
			--print-xml                \
			--autostart                \
			--boot network,hd,menu=on  \
			--video qxl,vram=256       \
			--channel spicevmc         \
			--name "$virt_node"        \
			--ram "$ram"               \
			--vcpus "$vcpus"           \
			--os-variant "ubuntu18.04" \
			--console pty,target_type=serial \
			--graphics spice,clipboard_copypaste=no,mouse_mode=client,filetransfer_enable=off \
			--cpu host-passthrough,cache.mode=passthrough  \
			--controller "$bus",model=virtio-scsi,index=0  \
			$disk_spec \
			$network_spec > "$virt_node.xml" &&
		virsh define "$virt_node.xml"
		virsh start "$virt_node" &

		maas_add_node ${virt_node} ${macaddr[0]} ${node_type} &

		# Wait some time before building the next, this helps with a lot of DHCP requests
		# and ensures that all VMs are commissioned and deployed.
		sleep ${build_fanout}

	done
	wait
}

destroy_vms() {
	for ((node="$node_start"; node<=node_count; node++)); do
		printf -v virt_node %s-%02d "$compute" "$node"

	        # If the domain is running, this will complete, else throw a warning 
	        virsh --connect qemu:///system destroy "$virt_node"

	        # Actually remove the VM
	        virsh --connect qemu:///system undefine "$virt_node"

	        # Remove the three storage volumes from disk
	        for ((disk=0;disk<${#disks[@]};disk++)); do
	                virsh vol-delete --pool "$virt_node" "$virt_node-d$((${disk} + 1)).img"
	        done
	        rm -rf "$storage_path/$virt_node/"
	        sync
	        rm -f "$virt_node.xml" \
			"/etc/libvirt/qemu/$virt_node.xml"    \
			"/etc/libvirt/storage/$virt_node.xml" \
			"/etc/libvirt/storage/autostart/$virt_node.xml"

			system_id=$(maas_system_id ${virt_node})
			maas ${maas_profile} machine delete ${system_id}
	done
}

while getopts ":cwd" opt; do
  case $opt in
	c)
		create_vms
		;;
	w)
		wipe_vms
		;;
	d)
		wipe_disks
		;;
	\?)
		echo "Invalid option: -$OPTARG" >&2
		;;
  esac
done

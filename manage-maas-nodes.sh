#!/bin/bash

# set -x

# This is the connection to this host, where the VM is being stored
qemu_connection="qemu+ssh://virsh@10.0.1.253/system"
qemu_password="seBGtkWFKZuFUFgig8NYU5uh"

# This is the connection to the MAAS server
maas_url="http://192.168.1.22:5240/MAAS/api/2.0/"
maas_api_key="z9cT7jE3BhmxcXkWWN:ew5WW9QdDMg8TXVnjt:NtKgJdfgA5FVw2YT9CnaKU87wJ5fTxKa"

# Storage area and type
storage_path="/var/lib/libvirt/maas-images"
storage_format="raw"

# Host prefix
compute="as1-maas-node"

# Number of control nodes, and theeir specifications
control_count=1
control_cpus=3
control_ram=8192

# Total number of VMs, and their specifications
node_count=11
node_start=1
node_cpus=2
node_ram=4096

# Models for nic and storage
nic_model="virtio"
stg_bus="scsi"

# The default network to use
network="maas"

# Sizes of disks for each of the VMs
d1=50
d2=20
d3=20

# how long you want to wait for commissioning
# default is 1200, i.e. 20 mins
commission_timeout=1200

# Time between building VMs
build_timeout=60

# This logs in to maas, and sets up the admin profile
maas_login()
{
	sudo apt -u update && sudo apt -y install maas-cli jq bc

	echo ${maas_api_key} | maas login admin ${maas_url} -
}

# Grabs the unique system)id for the host human readable hostname
maas_machine_id()
{
	node_name=$1

	maas admin machines read hostname=${node_name} | jq ".[].system_id" | sed s/\"//g
}

# Adds the VM into MAAS
maas_add_node()
{
	node_name=$1
	mac_addr=$2
	node_type=$3

	maas admin machines create \
		hostname=${node_name} \
		mac_addresses=${mac_addr} \
		architecture=amd64/generic \
		power_type=virsh \
		power_parameters_power_id=${node_name} \
		power_parameters_power_address=${qemu_connection} \
		power_parameters_power_pass=${qemu_password}

	system_id=$(maas_machine_id ${node_name})

	time_start=$(date +%s)
	time_end=${time_start}
	status_name=$(maas admin machine read ${system_id} | jq ".status_name" | sed s/\"//g)
	while [[ ${status_name} != "Ready" ]] && [[ $( echo ${time_end} - ${time_start} | bc ) -le ${commission_timeout} ]]
	do
		sleep 20
		status_name=$(maas admin machine read ${system_id} | jq ".status_name" | sed s/\"//g)
		time_end=$(date +%s)
	done

	# Tags the machine (TODO: This doesn't work yet)
	maas admin machine update ${system_id} tags="${node_type}"

	maas_auto_assign_networks ${system_id}
}

# Attempts to auto assign all the networks for a host
maas_auto_assign_networks()
{
	system_id=$1
	node_interfaces=$(maas admin interfaces read ${system_id} | jq ".[] | {id:.id, name:.name, mode:.links[].mode, subnet:.links[].subnet.id }" --compact-output)
	for interface in ${node_interfaces}
	do
		int_id=$(echo $interface | jq ".id" | sed s/\"//g)
		subnet_id=$(echo $interface | jq ".subnet" | sed s/\"//g)
		mode=$(echo $interface | jq ".mode" | sed s/\"//g)
		if [[ $mode != "auto" ]] ; then
			maas admin interface link-subnet ${system_id} ${int_id} mode="AUTO" subnet=${subnet_id}
		fi
	done
}

create_vms() {
	maas_login
	create_storage
	build_vms
}


wipe_vms() {
	maas_login
	destroy_vms
}

create_storage() {
	for ((machine="$node_start"; machine<=node_count; machine++)); do
		printf -v maas_node %s-%02d "$compute" "$machine"
		mkdir -p "$storage_path/$maas_node"
		/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d1.img" "$d1"G &
		/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d2.img" "$d2"G &
		/usr/bin/qemu-img create -f "$storage_format" "$storage_path/$maas_node/$maas_node-d3.img" "$d3"G &
	done
	wait
}

wipe_disks() {
	for ((machine="$node_start"; machine<=node_count; machine++)); do
		printf -v maas_node %s-%02d "$compute" "$machine"
		virsh --connect qemu:///system shutdown "$maas_node"
		rm -rf "$storage_path/$maas_node/$maas_node-d1.img" &
		rm -rf "$storage_path/$maas_node/$maas_node-d2.img" &
		rm -rf "$storage_path/$maas_node/$maas_node-d3.img" &
	done
	create_storge
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
		macaddr1=$(printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))")
		macaddr2=$(printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))")
		macaddr3=$(printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))")
		macaddr4=$(printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))")
		macaddr5=$(printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))")

		virt-install -v --noautoconsole   \
				--print-xml               \
				--autostart               \
				--boot network,hd,menu=on \
				--video qxl,vram=256      \
				--channel spicevmc        \
				--name "$virt_node"       \
				--ram "$ram"              \
				--vcpus "$vcpus"          \
				--console pty,target_type=serial \
				--graphics spice,clipboard_copypaste=no,mouse_mode=client,filetransfer_enable=off \
				--cpu host-passthrough,cache.mode=passthrough  \
				--controller "$bus",model=virtio-scsi,index=0  \
				--disk path="$storage_path/$virt_node/$virt_node-d1.img,format=$storage_format,size=$d1,bus=$bus,io=native,cache=directsync" \
				--disk path="$storage_path/$virt_node/$virt_node-d2.img,format=$storage_format,size=$d2,bus=$bus,io=native,cache=directsync" \
				--disk path="$storage_path/$virt_node/$virt_node-d3.img,format=$storage_format,size=$d3,bus=$bus,io=native,cache=directsync" \
				--network=bridge="br-enp1s0",mac="$macaddr1",model=$nic_model \
				--network=bridge="br-enp1s0.301",mac="$macaddr2",model=$nic_model \
				--network=bridge="br-enp1s0.302",mac="$macaddr3",model=$nic_model \
				--network=bridge="br-enp1s0.303",mac="$macaddr4",model=$nic_model \
				--network=bridge="br-enp1s0.304",mac="$macaddr5",model=$nic_model > "$virt_node.xml" &&
		virsh define "$virt_node.xml"
		virsh start "$virt_node" &

		maas_add_node ${virt_node} ${macaddr1} ${node_type} &

		# Wait some time before building the next, this helps with a lot of DHCP requests
		# and ensures that all VMs are commissioned and deployed.
		sleep ${build_timeout}

	done
	wait
}

destroy_vms() {
	for ((node="$node_start"; node<=node_count; node++)); do
		printf -v compute_node %s-%02d "$compute" "$node"

	        # If the domain is running, this will complete, else throw a warning 
	        virsh --connect qemu:///system destroy "$compute_node"

	        # Actually remove the VM
	        virsh --connect qemu:///system undefine "$compute_node"

	        # Remove the three storage volumes from disk
	        for disk in {1..3}; do
	                virsh vol-delete --pool "$compute_node" "$compute_node-d${disk}.img"
	        done
	        rm -rf "$storage_path/$compute_node/"
	        sync
	        rm -f "$compute_node.xml" \
			"/etc/libvirt/qemu/$compute_node.xml"    \
			"/etc/libvirt/storage/$compute_node.xml" \
			"/etc/libvirt/storage/autostart/$compute_node.xml"

			machine_id=$(maas_machine_id ${compute_node})
			maas admin machine delete ${machine_id}
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


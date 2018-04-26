#!/bin/bash

# set -x

storage_path="/storage/images/maas"
fmt="qcow2"
bootstrap="maas-bootstrap"
compute="maas-node"
node_count=10
nic_model="virtio"
network="maas"

create_vms() {
	# make_bootnode
	create_storage
	build_vms
}

wipe_vms() {
	destroy_vms
}

create_volumes() {
        compute_name="$1"
        node_name="$1"

        /usr/bin/qemu-img create -f "$fmt" "$storage_path/$compute_name/$node_name-d1.$fmt" 40G &
        /usr/bin/qemu-img create -f "$fmt" "$storage_path/$compute_name/$node_name-d2.$fmt" 20G &
        /usr/bin/qemu-img create -f "$fmt" "$storage_path/$compute_name/$node_name-d3.$fmt" 20G &
}

generate_mac() {
        printf '52:54:00:63:%02x:%02x\n' "$((RANDOM%256))" "$((RANDOM%256))"
}

make_bootnode() {
        ram="2048"
        vcpus="2"
        bus="scsi"

        virt-install --noautoconsole --print-xml \
                --boot network,hd,menu=on        \
                --graphics spice        \
                --video qxl             \
                --channel spicevmc      \
                --name "$bootstrap"     \
                --ram "$ram"            \
                --vcpus "$vcpus"        \
                --controller "$bus",model=virtio-scsi,index=0 \
                --disk path="$storage_path/$compute_name/$node_name-d1.$fmt,format=$fmt,size=40,bus=$bus,cache=writeback" \
                --disk path="$storage_path/$compute_name/$node_name-d2.$fmt,format=$fmt,size=20,bus=$bus,cache=writeback" \
                --disk path="$storage_path/$compute_name/$node_name-d3.$fmt,format=$fmt,size=20,bus=$bus,cache=writeback" \
                --network=network=$network,mac="$(generate_mac)",model=$nic_model \
                --network=network=$network,mac="$(generate_mac)",model=$nic_model > "$bootstrap.xml"

        # virsh define "$bootstrap".xml
        # mkdir -p "$storage_path/$bootstrap"
		# makevols "$bootstrap"
		# make_bootnode
}


create_storage() {
	for machine in $(seq -w 01 $node_count); do
	        mkdir -p "$storage_path/$compute-$machine"
	        create_volumes "$compute-$machine"
	done
}


build_vms() {
	for virt in $(seq -w 01 $node_count); do
	        ram="4096"
	        vcpus="4"
	        bus="scsi"
	        macaddr=$(generate_mac)

	        virt-install --noautoconsole --print-xml \
	                --boot network,hd,menu=on        \
	                --graphics spice                 \
	                --video qxl                      \
	                --channel spicevmc               \
	                --name "$compute-$virt"          \
	                --ram "$ram"                     \
	                --vcpus "$vcpus"                 \
	                --controller "$bus",model=virtio-scsi,index=0  \
	                --disk path="$storage_path/$compute-$virt/$compute-$virt-d1.$fmt,format=$fmt,size=40,bus=$bus,cache=writeback" \
	                --disk path="$storage_path/$compute-$virt/$compute-$virt-d2.$fmt,format=$fmt,size=20,bus=$bus,cache=writeback" \
	                --disk path="$storage_path/$compute-$virt/$compute-$virt-d3.$fmt,format=$fmt,size=20,bus=$bus,cache=writeback" \
	                --network=network=$network,mac="$macaddr",model=$nic_model > "$compute-$virt.xml"

	        virsh define "$compute-$virt.xml"
	        # virsh start "$compute-$virt"
	done
}

destroy_vms() {
	for node in $(seq -w 01 $node_count); do
	        # If the domain is running, this will complete, else throw a warning 
	        virsh --connect qemu:///system destroy "$compute-$node"

	        # Actually remove the VM
	        virsh --connect qemu:///system undefine "$compute-$node"

	        # Remove the three storage volumes from disk
	        for disk in {1..3}; do
	                virsh vol-delete --pool "$compute-$node" "$compute-$node-d$disk.qcow2"
	        done
	        rm -rf "$storage_path/$compute-$node/"
	        sync
	        rm "$compute-$node.xml" "/etc/libvirt/storage/$compute-$node.xml" "/etc/libvirt/storage/autostart/$compute-$node.xml"
	done
}

while getopts ":cwg" opt; do
  case $opt in
    c)
		create_vms
 	;;
    w)
		wipe_vms
	;;
	\?)
		echo "Invalid option: -$OPTARG" >&2
	;;
  esac
done


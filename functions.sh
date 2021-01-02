#!/bin/bash

# how long you want to wait for commissioning
# default is 1200, i.e. 20 mins
state_timeout=1200

install_deps()
{
    # Install some of the dependent packages
    deps="jq"
    if [[ "$0" =~"manage-maas" ]] ; then
        deps+=" virtinst"
    fi
    sudo apt -y update && sudo apt -y install ${deps}

    # We install the snap, as maas-cli is not in distributions, this ensures
    # that the package we invoke would be consistent
    sudo snap install maas --channel=${maas_version}/stable
}

# Ensures that any dependent packages are installed for any MAAS CLI commands
# This also logs in to MAAS, and sets up the admin profile
maas_login()
{
    # Login to MAAS using the API key and the endpoint
    login=$(echo ${maas_api_key} | maas login ${maas_profile} ${maas_endpoint} -)
}

# Grabs the unique system_id for the host human readable hostname
maas_system_id()
{
    node_name=$1

    maas ${maas_profile} machines read hostname=${node_name} | jq ".[].system_id" | sed s/\"//g
}

# Based on the nodename, finds the pod id, if it exists
maas_pod_id()
{
    node_name=$1

    maas ${maas_profile} pods read | jq ".[] | {pod_id:.id, hyp_name:.name}" --compact-output | \
        grep ${node_name} | jq ".pod_id" | sed s/\"//g
}

machine_add_tag()
{
    system_id=$1
    tag=$2

    # If the tag doesn't exist, then create it
    if [[ $(maas ${maas_profile} tag read ${tag}) == "Not Found" ]] ; then
        case $tag in
            "pod-console-logging")
                kernel_opts="console=tty1 console=ttyS0"
                ;;
            *)
                kernel_opts=""
                ;;
        esac
        tag_create=$(maas ${maas_profile} tags create name=${tag} kernel_opts=${kernel_opts})
    fi

    # Assign the tag to the machine
    tag_update=$(maas ${maas_profile} tag update-nodes ${tag} add=${system_id})
}

# This takes the system_id, and ensures that the machine is in $state state
# You may want to tweak the commission_timeout above in somehow it's failing
# and needs to be done quicker
ensure_machine_in_state()
{
    system_id=$1
    state=$2

    # TODO: add a $3 to be able to customise the timeout
    # timout= if [[ $3 == "" ]] ; then state_timeout else $3 ; fi
    timeout=${state_timeout}

    # The epoch time when this part started
    time_start=$(date +%s)

    # variable that will be used to check against for the timeout
    time_end=${time_start}

    # The initial state of the system
    status_name=$(maas ${maas_profile} machine read ${system_id} | jq ".status_name" | sed s/\"//g)

    # We will continue to check the state of the machine to see if it is in
    # $state or the timeout has occured, which defaults to 20 mins
    while [[ ${status_name} != "${state}" ]] && [[ $(( ${time_end} - ${time_start} )) -le ${timeout} ]]
    do
        # Check every 20 seconds of the state
        sleep 20

        # Grab the current state
        status_name=$(maas ${maas_profile} machine read ${system_id} | jq ".status_name" | sed s/\"//g)

        # Grab the current time to compare against
        time_end=$(date +%s)
    done
}

# Adds the VM into MAAS
maas_add_node()
{
    node_name=$1
    mac_addr=$2
    node_type=$3

    machine_type="vm"
    [[ $node_type == "physical" ]] && machine_type="$node_type"

    if [[ $machine_type == "vm" ]] ; then
        power_type="virsh"
        power_params="power_parameters_power_id=${node_name}"
        power_params+=" power_parameters_power_address=qemu+ssh://${virsh_user}@${hypervisor_ip}/system"
        power_params+=" power_parameters_power_pass=${qemu_password}"
    else
        power_type="manual"
        power_params=""
    fi

    # Check if the system already exists
    system_id=$(maas_system_id ${node_name})

    # This command creates the machine in MAAS, if it doesn't already exist.
    # This will then automatically turn the machines on, and start
    # commissioning.
    if [[ -z "$system_id" ]] ; then
        machine_create=$(maas ${maas_profile} machines create \
            hostname=${node_name}            \
            mac_addresses=${mac_addr}        \
            architecture=amd64/generic       \
            power_type=${power_type} ${power_params})
        system_id=$(echo $machine_create | jq .system_id | sed s/\"//g)

        ensure_machine_in_state ${system_id} "Ready"

        maas_assign_networks ${system_id}
    else
        boot_int=$(maas ${maas_profile} machine read ${system_id} | jq ".boot_interface | {mac:.mac_address, int_id:.id}")

        if [[ $mac_addr != "$(echo $boot_int | jq .mac | sed s/\"//g)" ]] ; then
            # A quick hack so that we can change the mac address of the interface.
            # The machine needs to be broken, ready or allocated.
            hack_commission=$(maas $maas_profile machine commission ${system_id})
            hack_break=$(maas $maas_profile machine mark-broken ${system_id})
            int_update=$(maas $maas_profile interface update ${system_id} $(echo $boot_int | jq .int_id | sed s/\"//g) mac_address=${mac_addr})
        fi
        machine_power_update=$(maas ${maas_profile} machine update ${system_id} \
            power_type=${power_type} ${power_params})
        commission_node ${system_id}
    fi

    machine_add_tag ${system_id} ${node_type}
    [[ $machine_type == "vm" ]] && machine_add_tag ${system_id} "pod-console-logging"

    [[ $machine_type == "physical" ]] && maas_create_partitions ${system_id}
}

commission_node()
{
    system_id=$1

    commission_machine=$(maas ${maas_profile} machine commission ${system_id})

    # Ensure that the machine is in ready state before the next step
    ensure_machine_in_state ${system_id} "Ready"

    maas_assign_networks ${system_id}
}

read_configs()
{
    configs=""
    configs+=" configs/default.config"
    configs+=" configs/maas.config"
    if [[ "$0" =~ "manage-maas" ]] ; then
        configs+=" configs/hypervisor.config"
    fi

    for config in $configs ; do
        read_config $config
    done
}

read_config()
{
    config=$1

    if [ ! -f $config ]; then
        printf "Error: missing config file. Please create the file '$config'.\n"
        exit 1
    else
        shopt -s extglob
        source "$config"
    fi
}

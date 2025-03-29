#!/bin/bash

#################################################################
# Variable Definitions
#################################################################

# ntfy.sh API Authorization Token
ntfy_auth="Authorization: Bearer [API TOKEN]"
ntfy_url="https://ntfy.sh/AlertChannel"

# Proxmox variables. The node you specify in 'baseurl' should be the last in the 'pve_nodes' array
baseurl='https://pve-001.home.mydomain.local:8006/api2/json'
pve_auth="Authorization: PVEAPIToken=[API TOKEN]"
pve_nodes=('pve-003' 'pve-002' 'pve-001')
# If you're using Ceph storage set the variable below to "1", otherwise set it to "0"
pve_ceph=1

# TrueNAS SSH Credential & IP Address
tns_ssh_pass="[SSH PASSWORD]"
tns_ip_addr="10.10.10.50"

# IPMI
# IPMI IP address for TrueNAS server
ipmi_ip_tns='10.10.10.60'
# IPMI IP addresses for each of the PVE servers
ipmi_ips_pve=('10.10.10.61' '10.10.10.62' '10.10.10.63')
# IPMI Credentials
ipmi_username="USERID"
ipmi_password="PASSW0RD"

#################################################################
#
#
#           DO NOT CHANGE ANYTHING BELOW HERE
#
#
#################################################################

#################################################################
# Function Definitions
#################################################################

notify-onbatt () {
    # Log message
    logger -t upssched-cmd "UPS is on battery, sending instant ntfy.sh notification."

    # Send ntfy.sh Notification
    curl -H "$ntfy_auth" -d "UPS on battery power" "$ntfy_url"
}

notify-online () {
    # Log message
    logger -t upssched-cmd "UPS is back on grid power. Sending ntfy.sh notification."

    # Send ntfy.sh Notification
    curl -H "$ntfy_auth" -d "UPS back on grid power" "$ntfy_url"
}

shutdown () {
    # Log message
    logger -t upssched-cmd "UPS has been on battery for more than 30 seconds. Gracefully shutting down PVE hosts and TrueNAS."

    # Send ntfy.sh notification
    curl -H "$ntfy_auth" -d "UPS on battery power for more than 30 seconds. Gracefully shutting down systems." "$ntfy_url"

    # Disable history substitution.
    set +H

    # Stop all vms and containers.
    echo 'Stopping all guests...'
    response=$(curl -k -H "$pve_auth" "$baseurl"/cluster/resources?type=vm | jq '[.data[] | {node, vmid, type, status} | select(.status == "running")]')

    for pve_node in ${pve_nodes[@]}
    do
    vms=$(jq ".[] | select(.node == \"$pve_node\") | .vmid" <<< $response)
    curl -k -H "$pve_auth" -X POST --data "vms=$vms" "$baseurl"/nodes/"$pve_node"/stopall
    done

    # Wait until all are stopped.
    running=true
    while [ $running != false ]
    do
    running=$(curl -k -H "$pve_auth" "$baseurl"/cluster/resources?type=vm | jq '.data | map(.status) | contains(["running"])')
    sleep 3
    done
    echo 'Guests stopped.'

    # Set Ceph Global Flags to prevent recovery and rebalance
    if [ "$pve_ceph" = "1" ]; then
        curl -k -X PUT --data "value=1" -H "$pve_auth" "$baseurl"/cluster/ceph/flags/noout
        curl -k -X PUT --data "value=1" -H "$pve_auth" "$baseurl"/cluster/ceph/flags/norebalance
        curl -k -X PUT --data "value=1" -H "$pve_auth" "$baseurl"/cluster/ceph/flags/norecover
    fi

    # Shutdown the cluster.
    echo "Shutting down nodes.."
    for pve_node in ${pve_nodes[@]}
    do
      curl -k -X POST --data "command=shutdown" -H "$pve_auth" "$baseurl"/nodes/"$pve_node"/status
    done
    echo "Shutdown command sent."

    # Shutdown TrueNAS
    sshpass -p "$tns_ssh_pass" ssh -o StrictHostKeyChecking=no root@"$tns_ip_addr" "shutdown -P now"

    # Create shutdown file. "online" function will only run if this file exists
    touch /etc/nut/shutdown
}

online () {
    # Log message
    logger -t upssched-cmd "UPS on line power for more than 60 seconds. Powering on hosts."

    # Send ntfy.sh notification
    curl -H "$ntfy_auth" -d "UPS on line power for more than 60 seconds. Powering on hosts." "$ntfy_url"

    # Disable history substitution.
    set +H

    # Power on TrueNAS
    ipmitool -H "$ipmi_ip_tns" -U "$ipmi_username" -P "$ipmi_password" power on

    # Wait 1 minute for TrueNAS to start booting
    sleep 60

    # Power on hosts
    for ipmi_ip in ${ipmi_ips_pve[@]}
    do
        ipmitool -H "$ipmi_ip" -U "$ipmi_username" -P "$ipmi_password" power on
    done

    # Wait 5 minutes for hosts to power on fully
    sleep 300

    # Unset Ceph Global Flags
    if [ "$pve_ceph" = "1" ]; then
        curl -k -X PUT --data "value=0" -H "$pve_auth" "$baseurl"/cluster/ceph/flags/noout
        curl -k -X PUT --data "value=0" -H "$pve_auth" "$baseurl"/cluster/ceph/flags/norebalance
        curl -k -X PUT --data "value=0" -H "$pve_auth" "$baseurl"/cluster/ceph/flags/norecover
    fi

    # Start all vms and containers.
    echo 'Starting all guests...'
    response=$(curl -k -H "$pve_auth" "$baseurl"/cluster/resources?type=vm | jq '[.data[] | {node, vmid, type, status} | select(.status == "stopped")]')

    for pve_node in ${pve_nodes[@]}
    do
    vms=$(jq ".[] | select(.node == \"$pve_node\") | .vmid" <<< $response)
    curl -k -H "$pve_auth" -X POST --data "vms=$vms" "$baseurl"/nodes/"$pve_node"/startall
    done

    # Remove shutdown file. "online" function will only run if this file exists
    rm /etc/nut/shutdown
}

#################################################################
# Event Handling
#################################################################

case $1 in
    notify-onbatt)
        # Send ntfy.sh notification
        notify-onbatt
        ;;
    notify-online)
        # Send ntfy.sh notification
        notify-online
        ;;
    shutdown)
        # Send ntfy.sh notification, shutdown PVE hosts, shutdown TrueNAS
        shutdown
        ;;
    online)
        # Power on TrueNAS & PVE hosts ONLY if shutdown file exists
        if [ -f "/etc/nut/shutdown" ]; then
            online
        fi
        ;;
    *)
        logger -t upssched-cmd "Unrecognized command: $1"
        ;;
esac

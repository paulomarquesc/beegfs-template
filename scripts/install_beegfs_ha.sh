#!/bin/bash

set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# -lt 2 ]; then
    echo "Usage: $0 <Mount> <hpcuser> <Number of Storage Nodes>"
    exit 1
fi

# Shares
SHARE_SCRATCH="/beegfs"
if [[ ! -z "${1:-}" ]]; then
	SHARE_SCRATCH=$1
fi

# User
HPC_USER=hpcuser
if [[ ! -z "${2:-}" ]]; then
	HPC_USER="$2"
fi

BEEGFS_NODE_COUNT=4
if [[ ! -z "${3:-}" ]]; then
	BEEGFS_NODE_COUNT=$3
fi

echo "using Scratch folder: $SHARE_SCRATCH"

SETUP_MARKER="$SHARE_SCRATCH/install_beegfs_ha.marker"
echo "Checking for setup marker at $SETUP_MARKER"
if [ -e "$SETUP_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

setup_ha()
{
	# Setting up Storage mirror group
	RESULT=$(sudo beegfs-ctl --listmirrorgroups --nodetype=storage)
	echo $RESULT
	if [ -z "$RESULT" ]; then
		echo "Setting up Storage mirror group..."

		sudo beegfs-ctl --addmirrorgroup --automatic --nodetype=storage
		sleep 20

		# Determining number of targets
		echo "Determining number of targets..."
		beegfs-ctl --listtargets --mirrorgroups > targetlist.txt

		NUM_TARGETS=$(expr $(cat targetlist.txt | wc -l) - 2)
		echo "Number is $NUM_TARGETS"
		if [ $NUM_TARGETS -gt 0 ]; then
			echo "Setting pattern...$NUM_TARGETS - $SHARE_SCRATCH"
			sudo beegfs-ctl --setpattern $SHARE_SCRATCH --numtargets=$NUM_TARGETS --chunksize=512k
		fi
	fi

	# Setting up Metadata mirror group
	RESULT=$(sudo beegfs-ctl --listmirrorgroups --nodetype=meta)
	echo $RESULT
	if [ -z "$RESULT" ]; then
		echo "Setting up Metadata mirror group..."
		sudo sudo beegfs-ctl --addmirrorgroup --automatic --nodetype=meta
		sleep 20
		
		CLIENT_ARR=()
		CLIENT_ARR+=($(beegfs-ctl --listnodes --nodetype=client | awk -F: '{print $2}' | cut -d ' ' -f 2 | tr -d $']'))
		for CLIENT_ID in "${CLIENT_ARR[@]}"
		do
			beegfs-ctl --removenode ${CLIENT_ID} --nodetype=client
		done

		sudo beegfs-ctl --mirrormd
	fi
}

reboot_nodes()
{
	beegfs-ctl --listnodes --nodetype=meta | awk '{print $1}' > nodelist
	beegfs-ctl --listnodes --nodetype=storage | awk '{print $1}' >> nodelist

	NODES=($(sort nodelist | uniq))
	NODES=("${NODES[@]%%:*}")

	for NODE in "${NODES[@]}"
	do
		echo "Rebooting node... $NODE"
		! sudo -H -u $HPC_USER bash -c 'ssh `whoami`@'$NODE' "sudo /sbin/shutdown -r now"'	
	done
}

restart_beegfs-client()
{
	echo "Trying to start beegfs-client  ..."
	counter=0
	while (! (systemctl restart beegfs-client))
	do
		counter=$((counter+1))
		echo "   Attempt $counter"  
		if [[ "$counter" -gt 15 ]]; then
			break
		fi 
	    
		RND_SECONDS=$(( RANDOM % (120 - 30 + 1 ) + 30 ))
		echo "Sleeping $RND_SECONDS seconds before retry..."
		sleep $RND_SECONDS
	done
}

wait_for_all_beegfs_nodes()
{
	counter=0
	while [ ! $(beegfs-ctl --listnodes --nodetype=storage | wc -l) -ge $BEEGFS_NODE_COUNT ]
	do
		echo "waiting for all nodes come up live..."

		counter=$((counter+1))
		if [[ "$counter" -gt 60 ]]; then
			break
		fi

		sleep 10
	done
}

# Main
restart_beegfs-client
wait_for_all_beegfs_nodes
setup_ha
reboot_nodes

touch $SETUP_MARKER

shutdown -r +1 &
exit 0

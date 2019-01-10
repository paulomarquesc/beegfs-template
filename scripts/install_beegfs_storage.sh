#!/bin/bash

set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# -lt 2 ]; then
    echo "Usage: $0 <ManagementHost> <Type (meta,storage,both,client)> <VolumeType> <Mount> <BeegfsHpcUserHomeFolder> <HpcUser> <HpcUID> <HpcGroup> <HpcGID> <customDomain>"
    exit 1
fi

MGMT_HOSTNAME=$1
BEEGFS_NODE_TYPE="$2"
VOLUME_TYPE=$3

# Shares
SHARE_SCRATCH="/beegfs"
if [[ ! -z "${4:-}" ]]; then
	SHARE_SCRATCH="$4"
fi

SHARE_HOME="/mnt/beegfshome"
if [[ ! -z "${5:-}" ]]; then
	SHARE_HOME="$5"
fi

HPC_USER=hpcuser
if [[ ! -z "${6:-}" ]]; then
	HPC_USER="$6"
fi

HPC_UID=7007
if [[ ! -z "${7:-}" ]]; then
	HPC_UID=$7
fi

HPC_GROUP=hpcgroup
if [[ ! -z "${8:-}" ]]; then
	HPC_GROUP="${8}"
fi

HPC_GID=7007
if [[ ! -z "${9:-}" ]]; then
	HPC_GID=${9}
fi

CUSTOMDOMAIN=""
if [[ ! -z "${10:-}" ]]; then
	CUSTOMDOMAIN="${10}"
	MGMT_HOSTNAME="$MGMT_HOSTNAME.$CUSTOMDOMAIN"
fi

BEEGFS_METADATA="/data/beegfs/meta"
BEEGFS_STORAGE="/data/beegfs/storage"

# Loading library
source ./library.sh

# Partitions all data disks attached to the VM and creates
# a RAID-0 volume with them.
#
setup_data_disks()
{
    mountPoint="$1"
    filesystem="$2"
    devices="$3"
    raidDevice="$4"
    createdPartitions=""

    # Loop through and partition disks until not found
    for disk in $devices; do
        fdisk -l /dev/$disk || break
        fdisk /dev/$disk << EOF
n
p
1


t
fd
w
EOF
        createdPartitions="$createdPartitions /dev/${disk}1"
    done
    
    sleep 10

    # Create RAID-0 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/$raidDevice --level 0 --raid-devices $devices $createdPartitions
        
        sleep 10
        
        mdadm /dev/$raidDevice

        if [ "$filesystem" == "xfs" ]; then
            mkfs -t $filesystem /dev/$raidDevice
	        export xfsuuid="UUID=`blkid |grep dev/$raidDevice |cut -d " " -f 2 |cut -c 7-42`"
            echo "$xfsuuid $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,sunit=1024,swidth=4096,nofail 0 2" >> /etc/fstab
        else
            mkfs.ext4 -i 2048 -I 512 -J size=400 -Odir_index,filetype /dev/$raidDevice
            sleep 5
            tune2fs -o user_xattr /dev/$raidDevice
	        export ext4uuid="UUID=`blkid |grep dev/$raidDevice |cut -d " " -f 2 |cut -c 7-42`"
            echo "$ext4uuid $mountPoint $filesystem noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
        fi
        
        sleep 10
        
        mount -a
    fi
}

setup_disks()
{      
    # Dump the current disk config for debugging
    #fdisk -l
    
    # Dump the scsi config
    #lsscsi
    
    # Get the root/OS disk so we know which device it uses and can ignore it later
    rootDevice=`mount | grep "on / type" | awk '{print $1}' | sed 's/[0-9]//g'`
    
    # Get the TMP disk so we know which device and can ignore it later
    tmpDevice=`mount | grep "on /mnt/resource type" | awk '{print $1}' | sed 's/[0-9]//g'`
    if [ -z $tmpDevice ]; then
        tmpDevice=`mount | grep "on /mnt type" | awk '{print $1}' | sed 's/[0-9]//g'`
    fi

    # Get the metadata and storage disk sizes from fdisk, we ignore the disks above
    metadataDiskSize=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | grep -v 'loop' | awk '{print $3}' | sort -n -r | tail -1`
    storageDiskSize=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | grep -v 'loop' | awk '{print $3}' | sort -n | tail -1`

    if [ "$metadataDiskSize" == "$storageDiskSize" ]; then
	
		# Compute number of disks
		nbDisks=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | grep -v 'loop' | wc -l`
		echo "nbDisks=$nbDisks"
		let nbMetadaDisks=nbDisks
		let nbStorageDisks=nbDisks
			
		if is_convergednode; then
			# If metadata and storage disks are the same size, we grab 1/3 for meta, 2/3 for storage
			
			# minimum number of disks has to be 2
			let nbMetadaDisks=nbDisks/3
			if [ $nbMetadaDisks -lt 2 ]; then
				let nbMetadaDisks=2
			fi
			
			let nbStorageDisks=nbDisks-nbMetadaDisks
		fi
		
		echo "nbMetadaDisks=$nbMetadaDisks nbStorageDisks=$nbStorageDisks"			
		
		metadataDevices="`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | grep $metadataDiskSize | grep -v 'loop' | awk '{print $2}' | awk -F: '{print $1}' | sort | head -$nbMetadaDisks | tr '\n' ' ' | sed 's|/dev/||g'`"
		storageDevices="`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | grep $storageDiskSize | grep -v 'loop' | awk '{print $2}' | awk -F: '{print $1}' | sort | tail -$nbStorageDisks | tr '\n' ' ' | sed 's|/dev/||g'`"
    else
        # Based on the known disk sizes, grab the meta and storage devices
        metadataDevices="`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | grep $metadataDiskSize | grep -v 'loop' | awk '{print $2}' | awk -F: '{print $1}' | sort | tr '\n' ' ' | sed 's|/dev/||g'`"
        storageDevices="`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | grep $storageDiskSize | grep -v 'loop' | awk '{print $2}' | awk -F: '{print $1}' | sort | tr '\n' ' ' | sed 's|/dev/||g'`"
    fi

    if is_storagenode; then
		mkdir -p $BEEGFS_STORAGE
		setup_data_disks $BEEGFS_STORAGE "xfs" "$storageDevices" "md10"
	fi
	
    if is_metadatanode; then
		mkdir -p $BEEGFS_METADATA    
		setup_data_disks $BEEGFS_METADATA "ext4" "$metadataDevices" "md20"
	fi
	
    mount -a
}

# Main

SETUP_MARKER=/var/local/install_beegfs.marker
if [ -e "$SETUP_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

systemctl stop firewalld
systemctl disable firewalld

# Disable SELinux
sed -i 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
setenforce 0 || true

set_hostname
install_pkgs
setup_disks
setup_user
tune_tcp
setup_domain
install_beegfs_repo
install_beegfs
download_lis
install_lis_in_cron

# Create marker file so we know we're configured
touch $SETUP_MARKER

shutdown -r +1 &
exit 0

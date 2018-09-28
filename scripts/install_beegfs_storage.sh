#!/bin/bash

#set -x
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
	SHARE_SCRATCH="$5"
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

BEEGFS_METADATA=/data/beegfs/meta
BEEGFS_STORAGE=/data/beegfs/storage

# Returns 0 if this node is the management node.
#
is_management()
{
    hostname | grep "$MGMT_HOSTNAME"
    return $?
}

is_metadatanode()
{
	if [ "$BEEGFS_NODE_TYPE" == "meta" ] || is_allnode || is_convergednode ; then 
		return 0
	fi
	return 1
}

is_storagenode()
{
	if [ "$BEEGFS_NODE_TYPE" == "storage" ] || is_allnode || is_convergednode ; then 
		return 0
	fi
	return 1
}

is_convergednode()
{
	if [ "$BEEGFS_NODE_TYPE" == "both" ]; then 
		return 0
	fi
	return 1
}

is_allnode()
{
	if [ "$BEEGFS_NODE_TYPE" == "all" ]; then 
		return 0
	fi
	return 1
	
}

is_client()
{
	if [ "$BEEGFS_NODE_TYPE" == "client" ] || is_allnode || is_management ; then 
		return 0
	fi
	return 1
}

# Sets hostname
set_hostname()
{
	if [[ -n $CUSTOMDOMAIN ]]; then
		HOSTNAME=`hostname`
		if ! grep -q $CUSTOMDOMAIN <<<"$HOSTNAME"; then
			echo "Setting up hostname to $HOSTNAME.$CUSTOMDOMAIN"
			sudo hostnamectl set-hostname "$HOSTNAME.$CUSTOMDOMAIN"
		fi
	fi
}

# Installs all required packages.
install_pkgs()
{
    sudo yum -y install epel-release
	sudo yum -y install kernel-devel kernel-headers kernel-tools-libs-devel gcc gcc-c++
    sudo yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs nfs-utils rpcbind mdadm wget python-pip openmpi openmpi-devel automake autoconf
}

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

    # Create RAID-0/RAID-5 volume
    if [ -n "$createdPartitions" ]; then
        devices=`echo $createdPartitions | wc -w`
        mdadm --create /dev/$raidDevice --level $VOLUME_TYPE --raid-devices $devices $createdPartitions
        
        sleep 10
        
        mdadm /dev/$raidDevice

        if [ "$filesystem" == "xfs" ]; then
            mkfs -t $filesystem /dev/$raidDevice
            echo "/dev/$raidDevice $mountPoint $filesystem rw,noatime,attr2,inode64,nobarrier,sunit=1024,swidth=4096,nofail 0 2" >> /etc/fstab
        else
            mkfs.ext4 -i 2048 -I 512 -J size=400 -Odir_index,filetype /dev/$raidDevice
            sleep 5
            tune2fs -o user_xattr /dev/$raidDevice
            echo "/dev/$raidDevice $mountPoint $filesystem noatime,nodiratime,nobarrier,nofail 0 2" >> /etc/fstab
        fi
        
        sleep 10
        
        mount /dev/$raidDevice
    fi
}

setup_disks()
{      
    # Dump the current disk config for debugging
    fdisk -l
    
    # Dump the scsi config
    lsscsi
    
    # Get the root/OS disk so we know which device it uses and can ignore it later
    rootDevice=`mount | grep "on / type" | awk '{print $1}' | sed 's/[0-9]//g'`
    
    # Get the TMP disk so we know which device and can ignore it later
    tmpDevice=`mount | grep "on /mnt/resource type" | awk '{print $1}' | sed 's/[0-9]//g'`

    # Get the metadata and storage disk sizes from fdisk, we ignore the disks above
    metadataDiskSize=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | awk '{print $3}' | sort -n -r | tail -1`
    storageDiskSize=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | awk '{print $3}' | sort -n | tail -1`

    if [ "$metadataDiskSize" == "$storageDiskSize" ]; then
	
		# Compute number of disks
		nbDisks=`fdisk -l | grep '^Disk /dev/' | grep -v $rootDevice | grep -v $tmpDevice | wc -l`
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
		
		metadataDevices="`fdisk -l | grep '^Disk /dev/' | grep $metadataDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | head -$nbMetadaDisks | tr '\n' ' ' | sed 's|/dev/||g'`"
		storageDevices="`fdisk -l | grep '^Disk /dev/' | grep $storageDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | tail -$nbStorageDisks | tr '\n' ' ' | sed 's|/dev/||g'`"
    else
        # Based on the known disk sizes, grab the meta and storage devices
        metadataDevices="`fdisk -l | grep '^Disk /dev/' | grep $metadataDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | tr '\n' ' ' | sed 's|/dev/||g'`"
        storageDevices="`fdisk -l | grep '^Disk /dev/' | grep $storageDiskSize | awk '{print $2}' | awk -F: '{print $1}' | sort | tr '\n' ' ' | sed 's|/dev/||g'`"
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

install_beegfs_repo()
{
	sudo wget -O /etc/yum.repos.d/beegfs-rhel7.repo https://www.beegfs.io/release/latest-stable/dists/beegfs-rhel7.repo
    sudo rpm --import https://www.beegfs.io/release/beegfs_7/gpg/RPM-GPG-KEY-beegfs
}

install_beegfs()
{
    echo "Installing BeeGFS..."

	# setup metata data
    if is_metadatanode; then
	 	echo "<==METADATA NODE==>"
		yum install -y beegfs-meta
		sed -i 's|^storeMetaDirectory.*|storeMetaDirectory = '$BEEGFS_METADATA'|g' /etc/beegfs/beegfs-meta.conf
		sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-meta.conf

		tune_meta

		systemctl daemon-reload
		systemctl enable beegfs-meta.service
	fi
	
	# setup storage
    if is_storagenode; then
		echo "<==STORAGE NODE==>"
		yum install -y beegfs-storage
		sed -i 's|^storeStorageDirectory.*|storeStorageDirectory = '$BEEGFS_STORAGE'|g' /etc/beegfs/beegfs-storage.conf
		sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-storage.conf

		tune_storage

		systemctl daemon-reload
		systemctl enable beegfs-storage.service
	fi

	# setup management
	if is_management; then
		echo "<==MANAGEMENT NODE==>"
		yum install -y beegfs-mgmtd beegfs-helperd beegfs-utils beegfs-admon
        
		# Install management server and client
		mkdir -p /data/beegfs/mgmtd
		sed -i 's|^storeMgmtdDirectory.*|storeMgmtdDirectory = /data/beegfs/mgmt|g' /etc/beegfs/beegfs-mgmtd.conf
		sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-admon.conf
		systemctl daemon-reload
		systemctl enable beegfs-mgmtd.service
		systemctl enable beegfs-admon.service
	fi

	if is_client; then
		echo "<==CLIENT NODE==>"
		yum install -y beegfs-client beegfs-helperd beegfs-utils
		# setup client
		sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-client.conf
		echo "$SHARE_SCRATCH /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf
	
		systemctl daemon-reload
		systemctl enable beegfs-helperd.service
		systemctl enable beegfs-client.service
	fi
}

tune_storage()
{
	echo "Tuning BeeGFS storage settings..."
	#echo deadline > /sys/block/md10/queue/scheduler
	#echo 4096 > /sys/block/md10/queue/nr_requests
	#echo 32768 > /sys/block/md10/queue/read_ahead_kb

	sed -i 's/^connMaxInternodeNum.*/connMaxInternodeNum = 800/g' /etc/beegfs/beegfs-storage.conf
	sed -i 's/^tuneNumWorkers.*/tuneNumWorkers = 128/g' /etc/beegfs/beegfs-storage.conf
	sed -i 's/^tuneFileReadAheadSize.*/tuneFileReadAheadSize = 32m/g' /etc/beegfs/beegfs-storage.conf
	sed -i 's/^tuneFileReadAheadTriggerSize.*/tuneFileReadAheadTriggerSize = 2m/g' /etc/beegfs/beegfs-storage.conf
	sed -i 's/^tuneFileReadSize.*/tuneFileReadSize = 256k/g' /etc/beegfs/beegfs-storage.conf
	sed -i 's/^tuneFileWriteSize.*/tuneFileWriteSize = 256k/g' /etc/beegfs/beegfs-storage.conf
	sed -i 's/^tuneWorkerBufSize.*/tuneWorkerBufSize = 16m/g' /etc/beegfs/beegfs-storage.conf	
}

tune_meta()
{
	echo "Tuning BeeGFS metadata settings..."
	# See http://www.beegfs.com/wiki/MetaServerTuning#xattr
	#echo deadline > /sys/block/md20/queue/scheduler
	#echo 128 > /sys/block/md20/queue/nr_requests
	#echo 128 > /sys/block/md20/queue/read_ahead_kb

	sed -i 's/^connMaxInternodeNum.*/connMaxInternodeNum = 800/g' /etc/beegfs/beegfs-meta.conf
	sed -i 's/^tuneNumWorkers.*/tuneNumWorkers = 128/g' /etc/beegfs/beegfs-meta.conf
}

tune_tcp()
{
	echo "Tuning TCP..."
    echo "net.ipv4.neigh.default.gc_thresh1=1100" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.neigh.default.gc_thresh2=2200" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.neigh.default.gc_thresh3=4400" | sudo tee -a /etc/sysctl.conf
}

setup_domain()
{
	echo "Setting up Domain..."
    if [[ -n "$CUSTOMDOMAIN" ]]; then

		# surround domain names separated by comma with " after removing extra spaces
		QUOTEDDOMAIN=$(echo $CUSTOMDOMAIN | sed -e 's/ //g' -e 's/"//g' -e 's/^\|$/"/g' -e 's/,/","/g')
		echo $QUOTEDDOMAIN

		echo "supersede domain-search $QUOTEDDOMAIN;" >> /etc/dhcp/dhclient.conf
	fi
}

setup_user()
{
	echo "Setting up user..."
    if [ ! -e "$SHARE_HOME" ]; then
        mkdir -p $SHARE_HOME
    fi

    if [ ! -e "$SHARE_SCRATCH" ]; then
        mkdir -p $SHARE_SCRATCH
    fi

	echo "$MGMT_HOSTNAME:$SHARE_HOME $SHARE_HOME    nfs4    rw,auto,_netdev 0 0" >> /etc/fstab
	mount -a
	mount
   
    groupadd -g $HPC_GID $HPC_GROUP

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    
    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

	useradd -c "HPC User" -g $HPC_GROUP -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER -M

	# Allow HPC_USER to reboot
    echo "%$HPC_GROUP ALL=NOPASSWD: /sbin/shutdown" | (EDITOR="tee -a" visudo)
    echo $HPC_USER | tee -a /etc/shutdown.allow
}


download_lis()
{
	echo "Downloading LIS..."
	wget -O /root/lis-rpms-4.2.6.tar.gz https://download.microsoft.com/download/6/8/F/68FE11B8-FAA4-4F8D-8C7D-74DA7F2CFC8C/lis-rpms-4.2.6.tar.gz
   	tar -xvzf /root/lis-rpms-4.2.6.tar.gz -C /root
}


install_lis_in_cron()
{
	echo "Install LIS script in CRON..."
	cat >  /root/lis_install.sh << "EOF"
#!/bin/bash
SETUP_LIS=/root/lispackage.setup

if [ -e "$SETUP_LIS" ]; then
    #echo "We're already configured, exiting..."
    exit 0
fi

cd /root/LISISO
./install.sh
touch $SETUP_LIS
shutdown -r +1
EOF
	chmod 700 /root/lis_install.sh
	! crontab -l > LIScron
	echo "@reboot /root/lis_install.sh >>/root/log.txt" >> LIScron
	crontab LIScron
	rm LIScron
}

SETUP_MARKER=/var/local/install_beegfs.marker
if [ -e "$SETUP_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

systemctl stop firewalld
systemctl disable firewalld

# Disable SELinux
sed -i 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
setenforce 0

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

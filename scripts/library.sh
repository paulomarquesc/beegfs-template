#!/bin/bash

# Returns 0 if this node is the management node.
#
is_management()
{
    hostname | grep "$MGMT_HOSTNAME"
    return $?
}

is_metadatanode()
{
	if [ "$BEEGFS_NODE_TYPE" == "meta" ] || is_convergednode ; then 
		return 0
	fi
	return 1
}

is_storagenode()
{
	if [ "$BEEGFS_NODE_TYPE" == "storage" ] || is_convergednode ; then 
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

is_client()
{
	if [ "$BEEGFS_NODE_TYPE" == "client" ] || is_management ; then 
		return 0
	fi
	return 1
}

# Installs all required packages.
install_kernel_pkgs()
{
	HOST="buildlogs.centos.org"
	CENTOS_MAJOR_VERSION=$(cat /etc/centos-release | awk '{print $4}' | awk -F"." '{print $1}')
	CENTOS_MINOR_VERSION=$(cat /etc/centos-release | awk '{print $4}' | awk -F"." '{print $3}')
	KERNEL_LEVEL_URL="https://$HOST/c$CENTOS_MAJOR_VERSION.$CENTOS_MINOR_VERSION.u.x86_64/kernel"

	cd ~/
	wget -r -l 1 $KERNEL_LEVEL_URL
	
	RESULT=$(find . -name "*.html" -print | xargs grep `uname -r`)

	RELEASE_DATE=$(echo $RESULT | awk -F"/" '{print $5}')

	KERNEL_ROOT_URL="$KERNEL_LEVEL_URL/$RELEASE_DATE/`uname -r`"

	KERNEL_PACKAGES=()
	KERNEL_PACKAGES+=("$KERNEL_ROOT_URL/kernel-devel-`uname -r`.rpm")
	KERNEL_PACKAGES+=("$KERNEL_ROOT_URL/kernel-headers-`uname -r`.rpm")
	KERNEL_PACKAGES+=("$KERNEL_ROOT_URL/kernel-tools-libs-devel-`uname -r`.rpm")
	
	sudo yum install -y ${KERNEL_PACKAGES[@]}
}

install_pkgs()
{
	sudo yum -y install epel-release
	sudo yum -y install kernel-devel kernel-headers kernel-tools-libs-devel gcc gcc-c++
	sudo yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs nfs-utils rpcbind mdadm wget python-pip openmpi openmpi-devel automake autoconf
	
	if [ ! -e "/usr/src/kernels/`uname -r`" ]; then
		echo "Kernel packages matching kernel version `uname -r` not installed. Executing alternate package install..."
		install_kernel_pkgs
	fi
}

install_beegfs_repo()
{
	sudo wget -O /etc/yum.repos.d/beegfs-rhel7.repo https://www.beegfs.io/release/beegfs_7_1/dists/beegfs_rhel7.repo
	sudo rpm --import https://www.beegfs.io/release/latest-stable/gpg/RPM-GPG-KEY-beegfs
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


setup_user()
{
	echo "Setting up user..."
    if [ ! -d "$SHARE_HOME" ]; then
        mkdir -p $SHARE_HOME
    fi

    if [ ! -d "$SHARE_SCRATCH" ]; then
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

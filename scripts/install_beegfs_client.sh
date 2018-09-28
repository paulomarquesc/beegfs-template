#!/bin/bash

#set -x
set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# -lt 2 ]; then
    echo "Usage: $0 <ManagementHost> <Type (meta,storage,both,client)> <clientCount> <sambaworkgroupname> <Mount> <BeeGfsSmbShareName> <BeegfsHpcUserHomeFolder> <HpcUser> <HpcUID> <HpcGroup> <HpcGID> <customDomain>"
    exit 1
fi

MGMT_HOSTNAME=$1
BEEGFS_NODE_TYPE="$2"
BEEGFS_CLIENT_COUNT="$3"
SAMBA_WORKGROUP_NAME="$4"

# Shares
SHARE_SCRATCH="/beegfs"
if [[ ! -z "${5:-}" ]]; then
	SHARE_SCRATCH="$5"
fi

BEEGFS_SMB_SHARENAME="$6"
if [[ ! -z "${6:-}" ]]; then
	BEEGFS_SMB_SHARENAME="$6"
fi

SHARE_HOME="/mnt/beegfshome"
if [[ ! -z "${7:-}" ]]; then
	SHARE_HOME="$7"
fi

# User
HPC_USER=hpcuser
if [[ ! -z "${8:-}" ]]; then
	HPC_USER="$8"
fi

HPC_UID=7007
if [[ ! -z "${9:-}" ]]; then
	HPC_UID=$9
fi

HPC_GROUP=hpc
if [[ ! -z "${10:-}" ]]; then
	HPC_GROUP="${10}"
fi

HPC_GID=7007
if [[ ! -z "${11:-}" ]]; then
	HPC_GID=${11}
fi

CUSTOMDOMAIN=""
if [[ ! -z "${12:-}" ]]; then
	CUSTOMDOMAIN="${12}"
fi

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

install_pkgs()
{
    sudo yum -y install epel-release
	sudo yum -y install kernel-devel kernel-headers kernel-tools-libs-devel gcc gcc-c++
    sudo yum -y install zlib zlib-devel bzip2 bzip2-devel bzip2-libs openssl openssl-devel openssl-libs nfs-utils rpcbind mdadm wget python-pip openmpi openmpi-devel automake autoconf
}

install_beegfs_repo()
{
    # Install BeeGFS repo    
	sudo wget -O /etc/yum.repos.d/beegfs-rhel7.repo https://www.beegfs.io/release/latest-stable/dists/beegfs-rhel7.repo
    sudo rpm --import https://www.beegfs.io/release/beegfs_7/gpg/RPM-GPG-KEY-beegfs
}

install_beegfs()
{
	# setup metata data
    if is_metadatanode; then
		yum install -y beegfs-meta
		sed -i 's|^storeMetaDirectory.*|storeMetaDirectory = '$BEEGFS_METADATA'|g' /etc/beegfs/beegfs-meta.conf
		sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-meta.conf

		tune_meta

		systemctl daemon-reload
		systemctl enable beegfs-meta.service
		
	fi
	
	# setup storage
    if is_storagenode; then
		yum install -y beegfs-storage
		sed -i 's|^storeStorageDirectory.*|storeStorageDirectory = '$BEEGFS_STORAGE'|g' /etc/beegfs/beegfs-storage.conf
		sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-storage.conf

		tune_storage

		systemctl daemon-reload
		systemctl enable beegfs-storage.service
	fi

	# setup management
	if is_management; then
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
		yum install -y beegfs-client beegfs-helperd beegfs-utils
		# setup client
		sed -i 's/^sysMgmtdHost.*/sysMgmtdHost = '$MGMT_HOSTNAME'/g' /etc/beegfs/beegfs-client.conf
		echo "$SHARE_SCRATCH /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf

		systemctl daemon-reload
		systemctl enable beegfs-helperd.service
		systemctl enable beegfs-client.service
	fi
}

tune_tcp()
{
    echo "net.ipv4.neigh.default.gc_thresh1=1100" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.neigh.default.gc_thresh2=2200" | sudo tee -a /etc/sysctl.conf
    echo "net.ipv4.neigh.default.gc_thresh3=4400" | sudo tee -a /etc/sysctl.conf
}

setup_domain()
{
    if [[ -n "$CUSTOMDOMAIN" ]]; then

		# surround domain names separated by comma with " after removing extra spaces
		QUOTEDDOMAIN=$(echo $CUSTOMDOMAIN | sed -e 's/ //g' -e 's/"//g' -e 's/^\|$/"/g' -e 's/,/","/g')
		echo $QUOTEDDOMAIN

		echo "supersede domain-search $QUOTEDDOMAIN;" >> /etc/dhcp/dhclient.conf
	fi
}

setup_user()
{
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
	wget -O /root/lis-rpms-4.2.6.tar.gz https://download.microsoft.com/download/6/8/F/68FE11B8-FAA4-4F8D-8C7D-74DA7F2CFC8C/lis-rpms-4.2.6.tar.gz
   	tar -xvzf /root/lis-rpms-4.2.6.tar.gz -C /root
}

install_lis_in_cron()
{
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
echo "End"
shutdown -r +1
EOF
	chmod 700 /root/lis_install.sh
	! crontab -l > LIScron
	echo "@reboot /root/lis_install.sh >>/root/log.txt" >> LIScron
	crontab LIScron
	rm LIScron
}

install_ha_in_cron()
{
	cat >  /root/ha_install.sh << "EOF"
SHARE_SCRATCH="/beegfs"
if [ -n "$1" ]; then
	SHARE_SCRATCH=$1
fi

echo "using Scratch folder: $SHARE_SCRATCH"

SETUP_MARKER="$SHARE_SCRATCH/install_beegfs_ha.marker"
echo "Checking for setup marker at $SETUP_MARKER"
if [ -e "$SETUP_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

touch $SETUP_MARKER

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
		sudo beegfs-ctl --mirrormd
	fi
}

RND_SECONDS=$(( RANDOM % (300 - 30 + 1 ) + 30 ))
echo "Sleeping $RND_SECONDS seconds before start ha configuration..."
sleep $RND_SECONDS

setup_ha

touch $SETUP_MARKER

echo "End"

exit 0
EOF
	chmod 700 /root/ha_install.sh
	! crontab -l > ha_cron
	echo "@reboot /root/ha_install.sh $SHARE_SCRATCH >>/root/ha_log.txt" >> ha_cron
	crontab ha_cron
	rm ha_cron
}

install_samba_in_cron()
{
	cat >  /root/samba_install.sh << "EOF"
#!/bin/bash
SETUP_SAMBA_MARKER=/var/local/install_samba.marker

if [ -e "$SETUP_SAMBA_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

# Functions
install_samba_pkgs()
{
	sudo yum install -y samba samba-common samba-client samba-winbind samba-winbind-clients
}

configure_samba()
{
	BEEGFS_SHARE="/beegfs"
	if [[ ! -z "${1:-}" ]]; then
		BEEGFS_SHARE="$1"
	fi

	BEEGFS_SMB_SHARE_NAME="beegfsshare"
	if [[ ! -z "${2:-}" ]]; then
		BEEGFS_SMB_SHARE_NAME="$2"
	fi

	SAMBA_WORKGROUP_NAME=$(</root/samba_workgroup_name.txt)
	HPC_USER=$(</root/hpc_user.txt)
	HPC_GROUP=$(</root/hpc_group.txt)

	BEEGFS_SMB_SHARED_FOLDER="$BEEGFS_SHARE/$BEEGFS_SMB_SHARE_NAME"
	if [ ! -e "$BEEGFS_SMB_SHARED_FOLDER" ]; then
		echo "Creating SMB shared folder... $BEEGFS_SMB_SHARED_FOLDER"
		mkdir $BEEGFS_SMB_SHARED_FOLDER
	fi

	echo "Enabling samba service..."
	systemctl enable smb

	echo "Configuring SAMBA..."
	if [ -e "/etc/samba/smb.conf" ]; then
		echo "Renaming original smb.conf to smb.conf.old..."
		mv "/etc/samba/smb.conf" "/etc/samba/smb.conf.old"
	fi

	if [ ! -e "/etc/samba/smb.conf" ]; then
echo "[global]
workgroup = $SAMBA_WORKGROUP_NAME
netbios name = BeeGFS
guest ok = yes
security = user
server role = standalone server
guest account = $HPC_USER
map to guest = Bad Password
passdb backend = tdbsam

[$BEEGFS_SMB_SHARE_NAME]
comment = BeeGFS shared file system
path = $BEEGFS_SMB_SHARED_FOLDER
public = yes
readonly = no
guest ok = yes
guest only = yes
browseable = yes
writeable = yes
create mask = 666
directory mask = 777
" | sudo tee /etc/samba/smb.conf > /dev/null
	fi

	if ! $(grep -q "Before=smb.service" /usr/lib/systemd/system/beegfs-client.service); then
		sudo awk '/Unit/ {print; print "Before=smb.service"; next}1' /usr/lib/systemd/system/beegfs-client.service | sudo tee /usr/lib/systemd/system/beegfs-client.service.1 > /dev/null
		sudo mv -f /usr/lib/systemd/system/beegfs-client.service.1 /usr/lib/systemd/system/beegfs-client.service
	fi

	# Changing default user owner and group
	chown -R $HPC_USER:$HPC_GROUP $BEEGFS_SMB_SHARED_FOLDER

	# Startig SAMBA
	systemctl start smb
}

# Main

# HA_MARKER="$BEEGFS_SHARE/install_beegfs_ha.marker"

# counter=0
# while (! (find $HA_MARKER))
# do
#     echo "Waiting for $HA_MARKER ..."
# 	counter=$((counter+1))
# 	if [[ "$counter" -gt 40 ]]; then
# 		break
# 	fi 
#     sleep 10
# done

# # Random wait before starting cfg
# RND_SECONDS=$(( RANDOM % (300 - 30 + 1 ) + 30 ))
# echo "Sleeping $RND_SECONDS seconds before start ha configuration..."
# sleep $RND_SECONDS

install_samba_pkgs
configure_samba

sudo touch $SETUP_SAMBA_MARKER

echo "End"
shutdown -r +1
EOF
	chmod 700 /root/samba_install.sh
	! crontab -l > smb_cron
	echo "@reboot /root/samba_install.sh $SHARE_SCRATCH $BEEGFS_SMB_SHARENAME >>/root/smb_log.txt" >> smb_cron
	crontab smb_cron
	rm smb_cron
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

# Disable tty requirement for sudo
sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

# Set client node count
echo $BEEGFS_CLIENT_COUNT | sudo tee "/root/beegfs_client_count.txt" > /dev/null
echo $SAMBA_WORKGROUP_NAME | sudo tee "/root/samba_workgroup_name.txt" > /dev/null
echo $HPC_USER | sudo tee "/root/hpc_user.txt" > /dev/null
echo $HPC_GROUP | sudo tee "/root/hpc_group.txt" > /dev/null

install_pkgs
tune_tcp
setup_domain
install_beegfs_repo
install_beegfs
download_lis
install_lis_in_cron $SHARE_SCRATCH
#install_ha_in_cron
install_samba_in_cron $SHARE_SCRATCH $BEEGFS_SMB_SHARENAME
setup_user

# Create marker file so we know we're configured
sudo touch $SETUP_MARKER

shutdown -r +1 &

exit 0

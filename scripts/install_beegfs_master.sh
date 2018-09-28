#!/bin/bash

set -x
#set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# -lt 2 ]; then
    echo "Usage: $0 <Type (meta,storage,both,client)> <BeegfsShareScratch> <BeegfsHpcUserHomeFolder> <customDomain>"
    exit 1
fi

MGMT_HOSTNAME=`hostname -s`

BEEGFS_METADATA="/data/beegfs/meta"
BEEGFS_STORAGE="/data/beegfs/storage"

BEEGFS_NODE_TYPE="$1"

# Shares
SHARE_SCRATCH="/beegfs"
if [[ ! -z "${2:-}" ]]; then
	SHARE_SCRATCH=$2
fi

SHARE_HOME="/mnt/beegfshome"
if [[ ! -z "${3:-}" ]]; then
	SHARE_HOME=$3
fi

CUSTOMDOMAIN=""
if [[ ! -z "${4:-}" ]]; then
	CUSTOMDOMAIN="$4"
	MGMT_HOSTNAME="$MGMT_HOSTNAME.$CUSTOMDOMAIN"
fi

# Returns 0 if this node is the management node.
#
is_management()
{
    hostname | grep "$MGMT_HOSTNAME"
    return $?
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
	sudo wget -O /etc/yum.repos.d/beegfs-rhel7.repo https://www.beegfs.io/release/latest-stable/dists/beegfs-rhel7.repo
    sudo rpm --import https://www.beegfs.io/release/beegfs_7/gpg/RPM-GPG-KEY-beegfs
}

install_beegfs()
{
       
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

setup_domain()
{
    if [[ -n "$CUSTOMDOMAIN" ]]; then

		# surround domain names separated by comma with " after removing extra spaces
		QUOTEDDOMAIN=$(echo $CUSTOMDOMAIN | sed -e 's/ //g' -e 's/"//g' -e 's/^\|$/"/g' -e 's/,/","/g')
		echo $QUOTEDDOMAIN

		echo "supersede domain-search $QUOTEDDOMAIN;" >> /etc/dhcp/dhclient.conf
	fi
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

install_pkgs
setup_domain
install_beegfs_repo
install_beegfs
download_lis
install_lis_in_cron

# Create marker file so we know we're configured
touch $SETUP_MARKER

shutdown -r +1 &
exit 0

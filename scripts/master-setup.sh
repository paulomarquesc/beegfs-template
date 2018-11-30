#!/bin/bash

set -xeuo pipefail

if [[ $(id -u) -ne 0 ]] ; then
    echo "Must be run as root"
    exit 1
fi

if [ $# -lt 2 ]; then
    echo "Usage: $0 <AdminUserName> <BeegfsShareScratch> <BeegfsHpcUserHomeFolder> <HpcUser> <HpcUID> <HpcGroup> <HpcGID>"
    exit 1
fi

USERNAME=$1

# Shares
SHARE_SCRATCH="/beegfs"
if [ -n "$2" ]; then
	SHARE_SCRATCH=$2
fi

SHARE_HOME="/mnt/beegfshome"
if [ -n "$3" ]; then
	SHARE_HOME=$3
fi

# User
HPC_USER=hpcuser
if [ -n "$4" ]; then
	HPC_USER=$4
fi

HPC_UID=7007
if [ -n "$5" ]; then
	HPC_UID=$5
fi

HPC_GROUP=hpcgroup
if [ -n "$6" ]; then
	HPC_GROUP=$6
fi

HPC_GID=7007
if [ -n "$7" ]; then
	HPC_GID=$7
fi

setup_folders()
{
    if [ ! -e "$SHARE_HOME" ]; then
        mkdir -p $SHARE_HOME
    fi

    if [ ! -e "$SHARE_SCRATCH" ]; then
        mkdir -p $SHARE_SCRATCH
    fi
}

setup_user()
{
    # disable selinux
    sed -i 's/enforcing/disabled/g' /etc/selinux/config
    setenforce permissive || true
    
    groupadd -g $HPC_GID $HPC_GROUP

    # Don't require password for HPC user sudo
    echo "$HPC_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
    
    # Disable tty requirement for sudo
    sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers
   
	useradd -c "HPC User" -g $HPC_GROUP -m -d $SHARE_HOME/$HPC_USER -s /bin/bash -u $HPC_UID $HPC_USER

    if [ ! -e "$SHARE_HOME/$HPC_USER/.ssh" ]; then
	    mkdir -p $SHARE_HOME/$HPC_USER/.ssh
    fi
	
	# Configure public key auth for the HPC user
	ssh-keygen -t rsa -f $SHARE_HOME/$HPC_USER/.ssh/id_rsa -q -P ""
	cat $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub >> $SHARE_HOME/$HPC_USER/.ssh/authorized_keys

	echo "Host *" > $SHARE_HOME/$HPC_USER/.ssh/config
	echo "    StrictHostKeyChecking no" >> $SHARE_HOME/$HPC_USER/.ssh/config
	echo "    UserKnownHostsFile /dev/null" >> $SHARE_HOME/$HPC_USER/.ssh/config
	echo "    PasswordAuthentication no" >> $SHARE_HOME/$HPC_USER/.ssh/config

	# Fix .ssh folder ownership
	chown -R $HPC_USER:$HPC_GROUP $SHARE_HOME/$HPC_USER

	# Fix permissions
	chmod 700 $SHARE_HOME/$HPC_USER/.ssh
	chmod 644 $SHARE_HOME/$HPC_USER/.ssh/config
	chmod 644 $SHARE_HOME/$HPC_USER/.ssh/authorized_keys
	chmod 600 $SHARE_HOME/$HPC_USER/.ssh/id_rsa
	chmod 644 $SHARE_HOME/$HPC_USER/.ssh/id_rsa.pub
	
	chown $HPC_USER:$HPC_GROUP $SHARE_SCRATCH

    # Allow HPC_USER to reboot
    echo "%$HPC_GROUP ALL=NOPASSWD: /sbin/shutdown" | (EDITOR="tee -a" visudo)
    echo $HPC_USER | tee -a /etc/shutdown.allow

}

setup_nfs()
{
	yum -y install nfs-utils nfs-utils-lib

    echo "$SHARE_HOME    *(rw,async,root_squash,anonuid=$HPC_UID,anongid=$HPC_GID,sec=sys)" >> /etc/exports

    #chown $HPC_USER:$HPC_GROUP $SHARE_HOME

    systemctl enable rpcbind || echo "Already enabled"
    systemctl enable nfs-server || echo "Already enabled"
    systemctl start rpcbind || echo "Already enabled"
    systemctl start nfs-server || echo "Already enabled"
}

SETUP_MARKER=/var/local/master-setup.marker
if [ -e "$SETUP_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

setup_folders
setup_nfs
setup_user

# Create marker file so we know we're configured
touch $SETUP_MARKER
exit 0

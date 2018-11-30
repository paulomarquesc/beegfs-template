#!/bin/bash

set -xeuo pipefail

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

SETUP_MARKER=/var/local/install_beegfs.marker
if [ -e "$SETUP_MARKER" ]; then
    echo "We're already configured, exiting..."
    exit 0
fi

# Loading library
source ./library.sh

# Main

systemctl stop firewalld
systemctl disable firewalld

# Disable SELinux
sed -i 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
setenforce 0 || true

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

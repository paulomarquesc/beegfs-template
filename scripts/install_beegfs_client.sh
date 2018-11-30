#!/bin/bash

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
server max protocol = SMB3
server min protocol = SMB3
client min protocol = SMB3
client max protocol = SMB3

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

# Loading library
source ./library.sh

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
install_samba_in_cron $SHARE_SCRATCH $BEEGFS_SMB_SHARENAME
setup_user

# Create marker file so we know we're configured
sudo touch $SETUP_MARKER

shutdown -r +1 &

exit 0

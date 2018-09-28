# Deploying management nodes
./Deploy-AzureResourceGroup.sh -g beegfs-rg-eus -l eastus -t deploy-beegfs-master.json -p deploy-beegfs-master-parameters.json -s pmcstorage08 -r support-rg

# Deploying server nodes (meta and storage)
./Deploy-AzureResourceGroup.sh -g beegfs-rg-eus -l eastus -t deploy-beegfs-nodes.json -p deploy-beegfs-nodes-parameters.json -s pmcstorage08 -r support-rg

# Deploying clients with SAMBA
./Deploy-AzureResourceGroup.sh -g beegfs-rg-eus -l eastus -t deploy-clients.json -p deploy-clients-parameters.json -s pmcstorage08 -r support-rg
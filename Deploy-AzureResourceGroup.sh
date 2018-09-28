#!/bin/bash

# NOTES:
# - Assumes Azure CLI 2.0 and Python 2.7 or greater installed
# - Assumes Key Vault service is deployed in Azure (for the sample code to work, any vault can be used but the script needs to be changed to support it),
#   a certificate PFX is imported there and a secret to encrypt the PFX before sending to the template is in place as well.
#   To still use the self-signed certificate, make sure you use -i flag.

set -e

TEMPLATE_FILE="azuredeploy.json"
TEMPLATE_PARAMETERS_FILE="azuredeploy.parameters.json"
RESOURCE_GROUP=""
LOCATION=""
STORAGE_ACCOUNT_NAME=""
SA_RESOURCE_GROUP=""
USE_SINGLE_RESOURCEGROUP="yes"

usage() 
{
    echo "Usage:"
    echo "  $0 [OPTIONS]"
    echo "    -g <RESOURCE_GROUP>                [Required]: Name of initial esource group for deployment. Creates or updates resource group."
    echo "    -l <REGION>                        [Required]: Location in which to create resources."
    echo "    -s <STORAGE_ACCT_NAME>             [Required]: Name of Storage Account. Creates or updates Storage Account."
    echo "    -r <STORAGE_ACCT_RG_NAME>          Name of the resource group where the Storage Account exists, it will default to the Resource Group name pass in -g argument."
    echo "    -t <TEMPLATE_PATH>                 Path to template file (relative to execution location of this script). Default: azuredeploy.json"
    echo "    -p <TEMPLATE_PARAM_PATH>           Path to template parameter file (relative to execution location of this script). Default: azuredeploy.parameters.json"
    echo
    echo "Example:"
    echo
    echo "      $0 -g testRg -l westus "
    echo 
    echo
}

while getopts "g:l:s:r:t:p:v:ma:h" opt; do
    case ${opt} in
        # Set Resource Group
        g )
            RESOURCE_GROUP=$OPTARG
            if [ ! -n "$SA_RESOURCE_GROUP" ] ; then
                SA_RESOURCE_GROUP=$OPTARG
            fi
            echo "    Resource Group Name: $RESOURCE_GROUP"
            ;;
        # Set Resources Location
        l )
            LOCATION=$OPTARG
            echo "    Location: $LOCATION"
            ;;
        # Set Storage Account Name
        s )
            STORAGE_ACCOUNT_NAME=$OPTARG
            echo "    Storage Account Name: $STORAGE_ACCOUNT_NAME"
            ;;
        # Storage Account Resource Group Name
        r )
            SA_RESOURCE_GROUP=$OPTARG
            echo "    Storage Account Resource Group Name: $SA_RESOURCE_GROUP"
            ;;
        # Template Path
        t )
            TEMPLATE_FILE=$OPTARG
            echo "    Template File: $TEMPLATE_FILE"
            ;;
        # Template Params File
        p )
            TEMPLATE_PARAMETERS_FILE=$OPTARG
            echo "    Template Parameters File: $TEMPLATE_PARAMETERS_FILE"
            ;;
        # Catch call, return usage and exit
        h  ) usage; exit 0;;
        \? ) echo "Unknown option: -$OPTARG" >&2; exit 1;;
        :  ) echo "Missing option argument for -$OPTARG" >&2; exit 1;;
        *  ) echo "Unimplemented option: -$OPTARG" >&2; exit 1;;
    esac
done
if [ $OPTIND -eq 1 ]; then echo; echo "No options were passed"; echo; usage; exit 1; fi
shift $((OPTIND -1))

if [ ! -x "$(command -v az)" ]; then
    echo "Azure CLI 2.0 not installed, please install it before proceeding"
    exit 1
fi

echo "Creating (if not created) initial resource group: $RESOURCE_GROUP"

# Create or update resource group
az group create \
    --name $RESOURCE_GROUP \
    --location $LOCATION

echo "Done."

# Always upload artifacts when deploying.
# Ensures that the latest code is uploaded.

# Lowercasing RG to be used for naming. And remove non-alphanumeric chars
safeRg=$(echo $RESOURCE_GROUP | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9]//g')

# If Storage Account is not set, then generate unique string
if [ -z "$STORAGE_ACCOUNT_NAME" ] ; then
    datetime=`date +%s`
    stgAccount="$safeRg$datetime"
    stgAccountLen=${#stgAccount}

    # Ensure string is less than 24
    if (( $stgAccountLen > 24 )) ; then
        echo "Storage Account Name exceeds max of 24 characters, truncating to less than 24 characters."
        stgAccount=$(echo $stgAccount | cut -c 1-23)
    fi

    STORAGE_ACCOUNT_NAME=$stgAccount

    echo "Storage Account name not provided. Creating new Storage Account: $STORAGE_ACCOUNT_NAME"

    # Create storage account
    az storage account create \
        --resource-group $RESOURCE_GROUP \
        --location $LOCATION \
        --sku Standard_LRS \
        --kind Storage \
        --name $STORAGE_ACCOUNT_NAME
fi

# The artifacts location is where the templates will live within the storage account
ARTIFACTS_CONTAINER_NAME="$safeRg-stageartifacts"

echo "Connecting to storage account: $STORAGE_ACCOUNT_NAME"
echo "  Using resource group name: $SA_RESOURCE_GROUP"
# Get storage connection string
CONNECTION_STRING=$(az storage account show-connection-string \
    --resource-group "$SA_RESOURCE_GROUP" \
    --name $STORAGE_ACCOUNT_NAME \
    --query connectionString)

echo "Found connection string: $CONNECTION_STRING"

echo "Creating or updating storage account container: $ARTIFACTS_CONTAINER_NAME"
# Create or update storage account container
az storage container create \
    --name $ARTIFACTS_CONTAINER_NAME \
    --public-access Off \
    --connection-string $CONNECTION_STRING
echo "Created (if not created) storage account container: $ARTIFACTS_CONTAINER_NAME"

# Set a 4 hour expiry time for a SAS token
# Note: Set the expiry time to allow enough time to complete the deployment.
starttime=$(python -c "from datetime import datetime; print format(datetime.utcnow(), '%Y-%m-%dT%H:%MZ')")
echo "Setting an start time to: $starttime"
expiretime=$(python -c "from datetime import datetime, timedelta; four_hours_from_now = datetime.utcnow() + timedelta(hours=4); print format(four_hours_from_now, '%Y-%m-%dT%H:%MZ')")
echo "Setting an expire time to: $expiretime"

echo "Creating a SAS token for access to: $ARTIFACTS_CONTAINER_NAME"
# Generate a SAS token
sasToken=$(az storage container generate-sas \
    --name $ARTIFACTS_CONTAINER_NAME \
    --expiry $expiretime \
    --start $starttime \
    --permissions r \
    --connection-string $CONNECTION_STRING | tr -d '"')

# Add a query
ARTIFACTS_LOCATION_SAS_TOKEN="?$sasToken"
echo "SAS token created: $ARTIFACTS_LOCATION_SAS_TOKEN"

STORAGE_ACCOUNT_URI=$(az storage account show \
    --resource-group $SA_RESOURCE_GROUP \
    --name $STORAGE_ACCOUNT_NAME \
    --query primaryEndpoints.blob | tr -d '"')

echo "Found Storage Account URI: $STORAGE_ACCOUNT_URI"

ARTIFACTS_LOCATION_URI="$STORAGE_ACCOUNT_URI$ARTIFACTS_CONTAINER_NAME"

echo "Created Storage Account Container URI: $ARTIFACTS_LOCATION_URI"

echo "Uploading files to blob container: $ARTIFACTS_CONTAINER_NAME"
az storage blob upload-batch \
    --destination $ARTIFACTS_CONTAINER_NAME \
    --source . \
    --connection-string $CONNECTION_STRING

echo "Uploaded files to blob."

echo "Deploying resource group..."
utcTime=$(python -c "import time; print(int(time.time()))")
#https://docs.microsoft.com/en-us/cli/azure/group/deployment?view=azure-cli-latest#az_group_deployment_create

az group deployment create \
    --resource-group $RESOURCE_GROUP \
    --template-file $TEMPLATE_FILE \
    --name "deploy-$utcTime" \
    --parameters @$TEMPLATE_PARAMETERS_FILE \
    --parameters _artifactsLocation=$ARTIFACTS_LOCATION_URI \
                 _artifactsLocationSasToken=$ARTIFACTS_LOCATION_SAS_TOKEN \
                 location=$LOCATION


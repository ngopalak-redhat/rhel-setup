#!/bin/bash

# Takes a backup of the running state of the host VM and creates a managed image[cite: 2].
#
# usage: 02_create_vm_image.sh [-c <config-file>] [<config-file>]

set -euo pipefail

# --- Pre-parse CLI Arguments for Custom Config File ---
CONFIG_FILE_CLI=""
TEMP_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)    CONFIG_FILE_CLI="$2"; shift 2 ;;
        --config=*)     CONFIG_FILE_CLI="${1#*=}"; shift ;;
        -*)             TEMP_ARGS+=("$1"); shift ;;
        *)
            # Auto-detect if positional arg is an existing config file path
            if [ -z "${CONFIG_FILE_CLI}" ] && [ -f "$1" ]; then
                CONFIG_FILE_CLI="$1"
            else
                TEMP_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

# Safe array expansion under set -u
if [ ${#TEMP_ARGS[@]} -gt 0 ]; then
    set -- "${TEMP_ARGS[@]}"
else
    set --
fi

# --- Source Configuration Files ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/../config/global.env"

# 1. Source default global config if present
if [ -f "${DEFAULT_CONFIG}" ]; then
    # shellcheck source=/dev/null
    source "${DEFAULT_CONFIG}" || true
fi

# 2. Source custom config file if provided via CLI argument or env variable
OVERRIDE_CONFIG="${CONFIG_FILE_CLI:-${CONFIG_FILE:-}}"
if [ -n "${OVERRIDE_CONFIG}" ]; then
    if [ -f "${OVERRIDE_CONFIG}" ]; then
        echo "Loading custom config from '${OVERRIDE_CONFIG}'..."
        # shellcheck source=/dev/null
        source "${OVERRIDE_CONFIG}" || true
    else
        echo "ERROR: Config file '${OVERRIDE_CONFIG}' not found." >&2
        exit 1
    fi
fi

# --- Environment Setup & Validation ---
if [ -z "${RESOURCE_GROUP:-}" ]; then
    echo "ERROR: RESOURCE_GROUP is not defined in config or environment." >&2
    exit 1
fi

if [ -z "${OWNER:-}" ]; then
    echo "ERROR: OWNER is not defined in config or environment." >&2
    exit 1
fi

INSTANCE_NAME="${INSTANCE_NAME:-${RESOURCE_GROUP}-azure-host}"
INSTANCE_NAME_PREFIX="${INSTANCE_NAME_PREFIX:-${INSTANCE_NAME}}"
MACHINE_IMAGE_PREFIX="${MACHINE_IMAGE_PREFIX:-${INSTANCE_NAME}}"

# Tags applied to every managed image this script creates
IMAGE_TAGS=(
    "keep-because=Managed VM backup for ${RESOURCE_GROUP}"
    "owner=${OWNER}"
)

# --- Functions ---

# Function to get a list of managed images sorted by creation time (newest first)
get_machine_images() {
    az image list \
        --resource-group "${RESOURCE_GROUP}" \
        --query "[?contains(name, '${MACHINE_IMAGE_PREFIX}')] | sort_by(@, &name) | reverse(@)[].name" \
        --output tsv
}

# --- Main Logic ---

# Check Azure CLI authentication
if ! az account show > /dev/null 2>&1; then
    echo "ERROR: Not authenticated with Azure CLI. Run 'az login' before executing." >&2
    exit 1
fi

# Step 1: Find running VM instance
echo "Checking if a VM instance with prefix '${INSTANCE_NAME_PREFIX}' is running in resource group '${RESOURCE_GROUP}'..."

RUNNING_VM_NAME=$(az vm list \
    --resource-group "${RESOURCE_GROUP}" \
    --show-details \
    --query "[?contains(name, '${INSTANCE_NAME_PREFIX}') && powerState=='VM running'].name | [0]" \
    --output tsv)

if [ -z "${RUNNING_VM_NAME}" ]; then
    echo "ERROR: No running VM instance found with prefix '${INSTANCE_NAME_PREFIX}' in '${RESOURCE_GROUP}'." >&2
    echo "Aborting script to prevent deleting old backups without a replacement." >&2
    exit 1
fi

echo "Found running VM instance: ${RUNNING_VM_NAME}"

# Retrieve OS Disk ID
OS_DISK_ID=$(az vm show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${RUNNING_VM_NAME}" \
    --query "storageProfile.osDisk.managedDisk.id" \
    --output tsv)

# Retrieve Hyper-V Generation dynamically (V1 or V2)
HYPERV_GEN=$(az vm show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${RUNNING_VM_NAME}" \
    --query "hyperVGeneration" \
    --output tsv)

# Fallback to V2 if hyperVGeneration property is omitted
HYPERV_GEN=${HYPERV_GEN:-V2}

# Retrieve the VM's region
VM_LOCATION=$(az vm show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${RUNNING_VM_NAME}" \
    --query "location" \
    --output tsv)

if [ -z "${VM_LOCATION}" ]; then
    echo "ERROR: Could not determine the region of '${RUNNING_VM_NAME}'." >&2
    exit 1
fi

echo "VM region: ${VM_LOCATION}"

TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
NEW_IMAGE_NAME="${MACHINE_IMAGE_PREFIX}-${TIMESTAMP}"
TEMP_SNAPSHOT_NAME="${NEW_IMAGE_NAME}-snap"

echo "Creating OS disk snapshot '${TEMP_SNAPSHOT_NAME}'..."

# Step 1a: Create disk snapshot
if az snapshot create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${TEMP_SNAPSHOT_NAME}" \
    --location "${VM_LOCATION}" \
    --source "${OS_DISK_ID}" \
    --output none; then

    echo "Snapshot created. Creating Managed Image (${HYPERV_GEN}): ${NEW_IMAGE_NAME}..."

    # Step 1b: Create Managed Image with explicit hyper-v generation flag
    if az image create \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${NEW_IMAGE_NAME}" \
        --location "${VM_LOCATION}" \
        --os-type Linux \
        --source "${TEMP_SNAPSHOT_NAME}" \
        --hyper-v-generation "${HYPERV_GEN}" \
        ${IMAGE_TAGS[@]+--tags "${IMAGE_TAGS[@]}"} \
        --output none; then

        echo "Successfully created new machine image: ${NEW_IMAGE_NAME}"
    else
        echo "ERROR: Failed to create machine image. Cleaning up temp snapshot..." >&2
        az snapshot delete --resource-group "${RESOURCE_GROUP}" --name "${TEMP_SNAPSHOT_NAME}" --output none || true
        exit 1
    fi

    # Clean up intermediate snapshot
    az snapshot delete --resource-group "${RESOURCE_GROUP}" --name "${TEMP_SNAPSHOT_NAME}" --output none
else
    echo "ERROR: Failed to create OS disk snapshot. Aborting cleanup phase." >&2
    exit 1
fi

echo "------------------------------------------------------"

# Step 2: List and delete old managed images
echo "Listing and pruning old machine images starting with '${MACHINE_IMAGE_PREFIX}'..."

ALL_IMAGES=$(get_machine_images)

if [ -z "${ALL_IMAGES}" ]; then
    IMAGE_COUNT=0
else
    IMAGE_COUNT=$(echo "${ALL_IMAGES}" | wc -l)
fi

if [ "${IMAGE_COUNT}" -gt 2 ]; then
    IMAGES_TO_DELETE=$(echo "${ALL_IMAGES}" | tail -n +3)
    DELETE_COUNT=$(echo "${IMAGES_TO_DELETE}" | wc -l)

    echo "Found ${IMAGE_COUNT} total images. Retaining the 2 newest."
    echo "Images to be deleted:"
    echo "${IMAGES_TO_DELETE}"

    printf "Do you want to proceed with deleting these %s image(s)? (y/N): " "${DELETE_COUNT}"
    read -r CONFIRMATION || CONFIRMATION=""

    case "$CONFIRMATION" in
        [Yy]*)
            echo "${IMAGES_TO_DELETE}" | while read -r IMAGE_NAME; do
                if [ -n "${IMAGE_NAME}" ]; then
                    echo "Deleting machine image: ${IMAGE_NAME}"
                    az image delete \
                        --resource-group "${RESOURCE_GROUP}" \
                        --name "${IMAGE_NAME}" \
                        --output none
                fi
            done
            echo "Cleanup complete."
            ;;
        *)
            echo "Deletion cancelled by user. Retention management skipped."
            ;;
    esac
else
    echo "Found ${IMAGE_COUNT} image(s). No deletion required (retaining up to 2)."
fi
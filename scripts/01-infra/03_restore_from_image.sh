#!/bin/bash

# Recreates the VM from the newest backup image created by 02_create_vm_image.sh[cite: 3].
#
# usage: 03_restore_from_image.sh [-c <config-file>] [<config-file>]

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

ADMIN_USER="${ADMIN_USER:-core}"
SSH_KEY_PUB="${SSH_KEY_PUB:-${HOME}/.ssh/id_rsa.pub}"
INSTANCE_NAME="${INSTANCE_NAME:-${RESOURCE_GROUP}-azure-host}"
MACHINE_IMAGE_PREFIX="${MACHINE_IMAGE_PREFIX:-${INSTANCE_NAME}}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME}"
OUTPUT_FILE="${OUTPUT_DIR}/${INSTANCE_NAME}-external-ip"

DELETE_AFTER=$(date -u -v+3d +"%Y-%m-%d" 2>/dev/null || date -u -d "+3 days" +"%Y-%m-%d")

VM_TAGS=(
    "owner=${OWNER}"
    "delete-after=${DELETE_AFTER}"
)

# --- Main Logic ---

# Check Azure CLI authentication
if ! az account show > /dev/null 2>&1; then
    echo "ERROR: Not authenticated with Azure CLI. Run 'az login' before executing." >&2
    exit 1
fi

# Create output directory if missing
echo "Ensuring output directory '${OUTPUT_DIR}' exists..."
mkdir -p "${OUTPUT_DIR}"

# Check if instance already exists
echo "Checking for existing instance '${INSTANCE_NAME}' in resource group '${RESOURCE_GROUP}'..."
VM_STATUS=$(az vm get-instance-view \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${INSTANCE_NAME}" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" \
    --output tsv 2>/dev/null || true)

if [ -n "${VM_STATUS}" ]; then
    if [ "${VM_STATUS}" == "VM running" ]; then
        echo "Instance '${INSTANCE_NAME}' already exists and is running."
    else
        echo "Instance '${INSTANCE_NAME}' exists with status '${VM_STATUS}'. Starting instance..."
        az vm start \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${INSTANCE_NAME}" \
            --output none
    fi
else
    # Fetch latest image matching prefix sorted by name (timestamp)
    read -r LATEST_MACHINE_IMAGE IMAGE_LOCATION < <(az image list \
        --resource-group "${RESOURCE_GROUP}" \
        --query "[?starts_with(name, '${MACHINE_IMAGE_PREFIX}')] | sort_by(@, &name) | reverse(@)[0].[name, location]" \
        --output tsv)

    if [ -z "${LATEST_MACHINE_IMAGE}" ]; then
        echo "ERROR: No machine images found starting with '${MACHINE_IMAGE_PREFIX}' in resource group '${RESOURCE_GROUP}'." >&2
        exit 1
    fi

    echo "Found latest machine image: ${LATEST_MACHINE_IMAGE} (${IMAGE_LOCATION})"

    EXTRA_FLAGS=()
    if [ -f "${SSH_KEY_PUB}" ]; then
        EXTRA_FLAGS=(--ssh-key-values "${SSH_KEY_PUB}")
    fi

    # Create VM instance
    echo "Creating instance '${INSTANCE_NAME}' from machine image '${LATEST_MACHINE_IMAGE}'..."
    echo "Location: ${IMAGE_LOCATION} (taken from image)."
    echo "VM will be tagged 'owner=${OWNER}' and 'delete-after=${DELETE_AFTER}'."
    az vm create \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${INSTANCE_NAME}" \
        --location "${IMAGE_LOCATION}" \
        --image "${LATEST_MACHINE_IMAGE}" \
        --admin-username "${ADMIN_USER}" \
        ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        ${VM_TAGS[@]+--tags "${VM_TAGS[@]}"} \
        --output none
fi

# Fetch and save external IP
echo "Getting external IP for instance '${INSTANCE_NAME}'..."
EXTERNAL_IP=$(az vm show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${INSTANCE_NAME}" \
    --show-details \
    --query "publicIps" \
    --output tsv)

if [ -n "${EXTERNAL_IP}" ]; then
    echo "Instance is ready!"
    echo "External IP: ${EXTERNAL_IP}"
    echo "${EXTERNAL_IP}" > "${OUTPUT_FILE}"
    echo "External IP saved to: ${OUTPUT_FILE}"
else
    echo "ERROR: Could not retrieve external IP address for '${INSTANCE_NAME}'." >&2
    exit 1
fi

# --- Status Report for Resources Outside the VM ---

echo
echo "------------------------------------------------------"
echo "Resources outside the VM (a managed image contains none of these):"

MISSING=0

report_resource() {
    if [ -n "$2" ]; then
        printf '  %-28s present\n' "$1"
    else
        printf '  %-28s MISSING   %s\n' "$1" "$3"
        MISSING=$((MISSING + 1))
    fi
}

# Check subnet NAT Gateway association
SUBNET_ID=$(az network vnet subnet list --resource-group "${RESOURCE_GROUP}" \
    --vnet-name "${INSTANCE_NAME}VNET" --query "[0].id" --output tsv 2>/dev/null || true)
SUBNET_NAT=""
if [ -n "${SUBNET_ID}" ]; then
    SUBNET_NAT=$(az network vnet subnet show --ids "${SUBNET_ID}" \
        --query "natGateway.id" --output tsv 2>/dev/null || true)
    [ "${SUBNET_NAT}" = "None" ] && SUBNET_NAT=""
fi
report_resource "NAT gateway on subnet" "${SUBNET_NAT}" \
    "pod VMs have no egress; ./setup_peerpods_azure_rhel_instance.sh"

# Check VM managed identity
VM_IDENTITY=$(az vm show --resource-group "${RESOURCE_GROUP}" --name "${INSTANCE_NAME}" \
    --query "identity.principalId" --output tsv 2>/dev/null || true)
[ "${VM_IDENTITY}" = "None" ] && VM_IDENTITY=""
report_resource "VM managed identity" "${VM_IDENTITY}" \
    "needed only to publish; PUBLISH_PODVM=1 ./build_coco_azure_rhel_instance.sh"

echo
if [ "${MISSING}" -eq 0 ]; then
    echo "Nothing outside the VM is missing."
else
    echo "${MISSING} resource(s) missing outside the VM."
fi
echo "SSH command: ssh ${ADMIN_USER}@${EXTERNAL_IP}"
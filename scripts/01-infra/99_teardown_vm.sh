#!/bin/bash

# Deletes the VM and infrastructure resources created by 01_provision_fresh_vm.sh,
# while explicitly preserving backup images created by 02_create_vm_image.sh[cite: 2, 4].
#
# usage: 99_teardown_vm.sh [-c <config-file>] [-y|--yes] [<config-file>]

set -euo pipefail

# --- Pre-parse CLI Arguments for Custom Config File & Flags ---
CONFIG_FILE_CLI=""
FORCE="${FORCE:-0}"
TEMP_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config)    CONFIG_FILE_CLI="$2"; shift 2 ;;
        --config=*)     CONFIG_FILE_CLI="${1#*=}"; shift ;;
        -y|--yes)       FORCE=1; shift ;;
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
MACHINE_IMAGE_PREFIX="${MACHINE_IMAGE_PREFIX:-${INSTANCE_NAME}}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME}"
OUTPUT_FILE="${OUTPUT_DIR}/${INSTANCE_NAME}-external-ip"
OWNER_TAG="${OWNER}"

FAILURES=0

# --- Functions ---

resource_name() {
    echo "${1##*/}"
}

note_failure() {
    echo "WARNING: failed to delete $1 '$2'." >&2
    FAILURES=$((FAILURES + 1))
}

is_backup_image() {
    local name="$1"
    [[ "${name}" =~ ^${MACHINE_IMAGE_PREFIX}-[0-9]{8}-[0-9]{6}$ ]]
}

# --- Main Logic ---

if ! az account show > /dev/null 2>&1; then
    echo "ERROR: Not authenticated with Azure CLI. Run 'az login' before executing." >&2
    exit 1
fi

echo "Looking for instance '${INSTANCE_NAME}' in resource group '${RESOURCE_GROUP}'..."

OS_DISKS=""
DATA_DISKS=""
NIC_IDS=""
PUBLIC_IP_IDS=""
NSG_IDS=""
VNET_NAMES=""

if az vm show --resource-group "${RESOURCE_GROUP}" --name "${INSTANCE_NAME}" \
    --output none 2>/dev/null; then
    VM_EXISTS=1

    # Collect Disks & NICs attached to the VM
    disk=$(az vm show --resource-group "${RESOURCE_GROUP}" --name "${INSTANCE_NAME}" \
        --query "storageProfile.osDisk.name" --output tsv 2>/dev/null || true)
    [ -n "${disk}" ] && OS_DISKS="${OS_DISKS}${disk}"$'\n'

    disk=$(az vm show --resource-group "${RESOURCE_GROUP}" --name "${INSTANCE_NAME}" \
        --query "storageProfile.dataDisks[].name" --output tsv 2>/dev/null || true)
    [ -n "${disk}" ] && DATA_DISKS="${DATA_DISKS}${disk}"$'\n'

    nics=$(az vm show --resource-group "${RESOURCE_GROUP}" --name "${INSTANCE_NAME}" \
        --query "networkProfile.networkInterfaces[].id" --output tsv 2>/dev/null || true)
    [ -n "${nics}" ] && NIC_IDS="${NIC_IDS}${nics}"$'\n'
else
    VM_EXISTS=0
    echo "Instance '${INSTANCE_NAME}' not found; checking for orphaned resources."

    ORPHANS=$(az disk list \
        --resource-group "${RESOURCE_GROUP}" \
        --query "[?starts_with(name, '${INSTANCE_NAME}_OsDisk_')].name" \
        --output tsv 2>/dev/null || true)
    [ -n "${ORPHANS}" ] && OS_DISKS="${OS_DISKS}${ORPHANS}"$'\n'

    ORPHANS=$(az network nic list \
        --resource-group "${RESOURCE_GROUP}" \
        --query "[?name=='${INSTANCE_NAME}VMNic'].id" \
        --output tsv 2>/dev/null || true)
    [ -n "${ORPHANS}" ] && NIC_IDS="${NIC_IDS}${ORPHANS}"$'\n'
fi

# Walk NICs for public IPs, NSGs, and VNETs
for NIC_ID in ${NIC_IDS}; do
    NIC_NAME=$(resource_name "${NIC_ID}")
    NIC_PIPS=$(az network nic show --ids "${NIC_ID}" \
        --query "ipConfigurations[].publicIPAddress.id" --output tsv 2>/dev/null || true)
    NIC_NSG=$(az network nic show --ids "${NIC_ID}" \
        --query "networkSecurityGroup.id" --output tsv 2>/dev/null || true)
    NIC_SUBNETS=$(az network nic show --ids "${NIC_ID}" \
        --query "ipConfigurations[].subnet.id" --output tsv 2>/dev/null || true)

    [ -n "${NIC_PIPS}" ] && PUBLIC_IP_IDS="${PUBLIC_IP_IDS}${NIC_PIPS}"$'\n'
    [ -n "${NIC_NSG}" ] && NSG_IDS="${NSG_IDS}${NIC_NSG}"$'\n'

    for SUBNET_ID in ${NIC_SUBNETS}; do
        VNET="${SUBNET_ID#*/virtualNetworks/}"
        VNET="${VNET%%/*}"
        [ -n "${VNET}" ] && VNET_NAMES="${VNET_NAMES}${VNET}"$'\n'
    done
    echo "  Found NIC: ${NIC_NAME}"
done

# Clean lists
OS_DISKS=$(echo "${OS_DISKS}" | grep -v '^$' | sort -u || true)
DATA_DISKS=$(echo "${DATA_DISKS}" | grep -v '^$' | sort -u || true)
NIC_IDS=$(echo "${NIC_IDS}" | grep -v '^$' | sort -u || true)
PUBLIC_IP_IDS=$(echo "${PUBLIC_IP_IDS}" | grep -v '^$' | sort -u || true)
NSG_IDS=$(echo "${NSG_IDS}" | grep -v '^$' | sort -u || true)
VNET_NAMES=$(echo "${VNET_NAMES}" | grep -v '^$' | sort -u || true)

# Summary
echo
echo "The following will be deleted from resource group '${RESOURCE_GROUP}':"
RESOURCE_COUNT=0
if [ "${VM_EXISTS}" -eq 1 ]; then
    echo "  VM             ${INSTANCE_NAME}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
fi
for ITEM in ${NIC_IDS}; do
    echo "  NIC            $(resource_name "${ITEM}")"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done
for ITEM in ${PUBLIC_IP_IDS}; do
    echo "  Public IP      $(resource_name "${ITEM}")"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done
for ITEM in ${NSG_IDS}; do
    echo "  NSG            $(resource_name "${ITEM}")"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done
for ITEM in ${VNET_NAMES}; do
    echo "  VNET           ${ITEM} (only if no devices remain attached)"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done
for ITEM in ${OS_DISKS} ${DATA_DISKS}; do
    echo "  Disk           ${ITEM}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done
if [ -f "${OUTPUT_FILE}" ]; then
    echo "  Local file     ${OUTPUT_FILE}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
fi

if [ "${RESOURCE_COUNT}" -eq 0 ]; then
    echo "  (nothing found)"
fi
echo "  Sweep          anything else tagged owner=${OWNER_TAG} without keep-because"

echo
echo "KEEPING: resource group '${RESOURCE_GROUP}', and backup images"
BACKUP_IMAGES=$(az image list --resource-group "${RESOURCE_GROUP}" \
    --query "[?starts_with(name, '${MACHINE_IMAGE_PREFIX}-')].name" --output tsv 2>/dev/null || true)
KEPT=0
for ITEM in ${BACKUP_IMAGES}; do
    if is_backup_image "${ITEM}"; then
        echo "         ${ITEM}"
        KEPT=$((KEPT + 1))
    fi
done
if [ "${KEPT}" -eq 0 ]; then
    echo "         (none - restore script will have nothing to restore from)"
fi

if [ "${FORCE}" -ne 1 ]; then
    echo
    printf "Do you want to proceed with deleting these %s item(s)? (y/N): " "${RESOURCE_COUNT}"
    read -r CONFIRMATION || CONFIRMATION=""
    case "${CONFIRMATION}" in
        [Yy]*) ;;
        *) echo "Deletion cancelled by user."; exit 0 ;;
    esac
fi

echo
echo "------------------------------------------------------"

# Execution of deletions
if [ "${VM_EXISTS}" -eq 1 ]; then
    echo "Deleting VM: ${INSTANCE_NAME}"
    az vm delete \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${INSTANCE_NAME}" \
        --yes \
        --output none || note_failure "VM" "${INSTANCE_NAME}"
fi

for ITEM in ${NIC_IDS}; do
    echo "Deleting NIC: $(resource_name "${ITEM}")"
    az network nic delete --ids "${ITEM}" --output none \
        || note_failure "NIC" "$(resource_name "${ITEM}")"
done

for ITEM in ${PUBLIC_IP_IDS}; do
    echo "Deleting public IP: $(resource_name "${ITEM}")"
    az network public-ip delete --ids "${ITEM}" --output none \
        || note_failure "public IP" "$(resource_name "${ITEM}")"
done

for ITEM in ${NSG_IDS}; do
    echo "Deleting NSG: $(resource_name "${ITEM}")"
    az network nsg delete --ids "${ITEM}" --output none \
        || note_failure "NSG" "$(resource_name "${ITEM}")"
done

SWEEP_SKIP=""
for ITEM in ${VNET_NAMES}; do
    IN_USE=$(az network vnet show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${ITEM}" \
        --query "length(subnets[].ipConfigurations[] | [])" \
        --output tsv 2>/dev/null || true)
    if [ "${IN_USE:-0}" -gt 0 ]; then
        echo "Keeping VNET '${ITEM}': ${IN_USE} IP configuration(s) still attached."
        SWEEP_SKIP="${SWEEP_SKIP}${ITEM}"$'\n'
        continue
    fi
    echo "Deleting VNET: ${ITEM}"
    az network vnet delete \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${ITEM}" \
        --output none || note_failure "VNET" "${ITEM}"
done

for ITEM in ${OS_DISKS} ${DATA_DISKS}; do
    echo "Deleting disk: ${ITEM}"
    az disk delete \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${ITEM}" \
        --yes \
        --output none || note_failure "disk" "${ITEM}"
done

if [ -f "${OUTPUT_FILE}" ]; then
    echo "Removing stale local file: ${OUTPUT_FILE}"
    rm -f "${OUTPUT_FILE}"
fi

# --- Backstop Sweep ---
# Protection against deleting backup images:
# 1. Query excludes resources containing the 'keep-because' tag (applied by 02_create_vm_image.sh).
# 2. Check is_backup_image in loop explicitly to ensure matching names are never deleted.
echo "Sweeping anything tagged owner=${OWNER_TAG} without keep-because..."
SWEPT=0
while read -r SWEEP_ID SWEEP_NAME SWEEP_TYPE; do
    [ -z "${SWEEP_ID}" ] && continue
    if [ "${SWEEP_TYPE}" = "Microsoft.Compute/images" ] && is_backup_image "${SWEEP_NAME}"; then
        echo "  Keeping ${SWEEP_NAME} (backup image)"
        continue
    fi
    if grep -qxF "${SWEEP_NAME}" <<< "${SWEEP_SKIP}"; then
        echo "  Keeping ${SWEEP_NAME} (still in use)"
        continue
    fi
    echo "  Deleting ${SWEEP_TYPE##*/}: ${SWEEP_NAME}"
    az resource delete --ids "${SWEEP_ID}" --output none \
        || note_failure "${SWEEP_TYPE##*/}" "${SWEEP_NAME}"
    SWEPT=$((SWEPT + 1))
done < <(az resource list --resource-group "${RESOURCE_GROUP}" \
    --query "[?tags.owner=='${OWNER_TAG}' && tags.\"keep-because\"==null].[id, name, type]" \
    --output tsv 2>/dev/null || true)
[ "${SWEPT}" -eq 0 ] && echo "  (nothing left)"

echo "------------------------------------------------------"

if [ "${FAILURES}" -gt 0 ]; then
    echo "Finished with ${FAILURES} failure(s). Remaining resources in '${RESOURCE_GROUP}':" >&2
    az resource list --resource-group "${RESOURCE_GROUP}" \
        --query "[].[name, type]" --output tsv
    exit 1
fi

echo "Deletion complete. Remaining resources in '${RESOURCE_GROUP}':"
REMAINING=$(az resource list --resource-group "${RESOURCE_GROUP}" \
    --query "[].[name, type]" --output tsv || true)
echo "${REMAINING:-  (none)}"
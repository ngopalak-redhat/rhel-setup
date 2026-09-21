#!/bin/bash

# Deletes all Azure resources created by 01_build_coco.sh and 02_setup_peerpods.sh:
# - Subnet NAT Gateway & Public IP
# - Active/leftover Pod VMs (podvm-*)
# - Imported & Local Pod VM Compute Galleries, Image Definitions, and Image Versions
# - Storage Account
# - Service Principal, Role Assignments, and local credential files
#
# usage: 99_teardown_coco.sh [-c <config-file>] [-y|--yes] [<config-file>]

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
            if [ -z "${CONFIG_FILE_CLI}" ] && [ -f "$1" ]; then
                CONFIG_FILE_CLI="$1"
            else
                TEMP_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

if [ ${#TEMP_ARGS[@]} -gt 0 ]; then
    set -- "${TEMP_ARGS[@]}"
else
    set --
fi

# --- Source Configuration Files ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/../config/global.env"

if [ -f "${DEFAULT_CONFIG}" ]; then
    # shellcheck source=/dev/null
    source "${DEFAULT_CONFIG}" || true
fi

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
OUTPUT_DIR="${OUTPUT_DIR:-$HOME}"

# NAT Gateway resources (created by 02_setup_peerpods.sh)
NAT_GATEWAY_NAME="${NAT_GATEWAY_NAME:-${INSTANCE_NAME}-podvm-nat}"
NAT_GATEWAY_IP_NAME="${NAT_GATEWAY_IP_NAME:-${INSTANCE_NAME}-podvm-nat-ip}"

# Galleries (community imported & local build)
PODVM_GALLERY="${PODVM_GALLERY:-${RESOURCE_GROUP}_podvm_gallery}"
PODVM_LOCAL_GALLERY="${PODVM_LOCAL_GALLERY:-${RESOURCE_GROUP}_podvm_local_gallery}"

# Storage Account & Service Principal
PODVM_STORAGE_ACCOUNT="${PODVM_STORAGE_ACCOUNT:-${RESOURCE_GROUP}podvm}"
SP_NAME="${SP_NAME:-${INSTANCE_NAME}-peerpods}"
SP_FILE="${SP_FILE:-${OUTPUT_DIR}/${INSTANCE_NAME}-peerpods-sp.json}"

FAILURES=0

note_failure() {
    echo "WARNING: failed to delete $1 '$2'." >&2
    FAILURES=$((FAILURES + 1))
}

# --- Main Logic ---

if ! az account show > /dev/null 2>&1; then
    echo "ERROR: Not authenticated with Azure CLI. Run 'az login' before executing." >&2
    exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id --output tsv)
RG_SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"

echo "Scanning for Confidential Containers & PeerPods resources in '${RESOURCE_GROUP}'..."

# 1. Active or orphaned Pod VMs created by Cloud API Adaptor
PODVM_NAMES=$(az vm list --resource-group "${RESOURCE_GROUP}" \
    --query "[?starts_with(name, 'podvm')].name" --output tsv 2>/dev/null || true)

# 2. NAT Gateway & NAT Public IP
NAT_GW_ID=$(az network nat gateway show --resource-group "${RESOURCE_GROUP}" \
    --name "${NAT_GATEWAY_NAME}" --query "id" --output tsv 2>/dev/null || true)

NAT_GW_SUBNETS=""
if [ -n "${NAT_GW_ID}" ]; then
    NAT_GW_SUBNETS=$(az network nat gateway show --ids "${NAT_GW_ID}" \
        --query "subnets[].id" --output tsv 2>/dev/null || true)
fi

NAT_GW_IP_ID=$(az network public-ip show --resource-group "${RESOURCE_GROUP}" \
    --name "${NAT_GATEWAY_IP_NAME}" --query "id" --output tsv 2>/dev/null || true)

# 3. Galleries, Image Definitions & Image Versions
GALLERY_NAMES=""
GALLERY_DEFS=""
GALLERY_VERSIONS=""

for GALLERY in "${PODVM_GALLERY}" "${PODVM_LOCAL_GALLERY}"; do
    az sig show --resource-group "${RESOURCE_GROUP}" --gallery-name "${GALLERY}" \
        --output none 2>/dev/null || continue
    GALLERY_NAMES="${GALLERY_NAMES}${GALLERY}"$'\n'

    for GALLERY_DEF in $(az sig image-definition list --resource-group "${RESOURCE_GROUP}" \
        --gallery-name "${GALLERY}" --query "[].name" --output tsv 2>/dev/null || true); do
        GALLERY_DEFS="${GALLERY_DEFS}${GALLERY}|${GALLERY_DEF}"$'\n'

        for GALLERY_VER in $(az sig image-version list --resource-group "${RESOURCE_GROUP}" \
            --gallery-name "${GALLERY}" --gallery-image-definition "${GALLERY_DEF}" \
            --query "[].name" --output tsv 2>/dev/null || true); do
            GALLERY_VERSIONS="${GALLERY_VERSIONS}${GALLERY}|${GALLERY_DEF}|${GALLERY_VER}"$'\n'
        done
    done
done

# 4. Storage Account
STORAGE_ID=$(az storage account show --resource-group "${RESOURCE_GROUP}" \
    --name "${PODVM_STORAGE_ACCOUNT}" --query "id" --output tsv 2>/dev/null || true)

# 5. Service Principal & Role Assignments
PRINCIPAL_IDS=""

# Service Principal ID
SP_APP_ID=$(az ad sp list --display-name "${SP_NAME}" --query "[0].appId" --output tsv 2>/dev/null || true)
SP_OBJECT_ID=$(az ad sp list --display-name "${SP_NAME}" --query "[0].id" --output tsv 2>/dev/null || true)
[ -n "${SP_OBJECT_ID}" ] && PRINCIPAL_IDS="${PRINCIPAL_IDS}${SP_OBJECT_ID}"$'\n'

# Host VM Managed Identity ID
HOST_IDENTITY=$(az vm show --resource-group "${RESOURCE_GROUP}" --name "${INSTANCE_NAME}" \
    --query "identity.principalId" --output tsv 2>/dev/null || true)
[ -n "${HOST_IDENTITY}" ] && [ "${HOST_IDENTITY}" != "None" ] && PRINCIPAL_IDS="${PRINCIPAL_IDS}${HOST_IDENTITY}"$'\n'

ROLE_ASSIGNMENT_IDS=""
for PRINCIPAL in ${PRINCIPAL_IDS}; do
    ASSIGNMENTS=$(az role assignment list --assignee "${PRINCIPAL}" --scope "${RG_SCOPE}" \
        --query "[].id" --output tsv 2>/dev/null || true)
    [ -n "${ASSIGNMENTS}" ] && ROLE_ASSIGNMENT_IDS="${ROLE_ASSIGNMENT_IDS}${ASSIGNMENTS}"$'\n'
done

ROLE_ASSIGNMENT_IDS=$(echo "${ROLE_ASSIGNMENT_IDS}" | grep -v '^$' | sort -u || true)

# --- Summary ---
echo
echo "The following CoCo & PeerPods resources will be deleted from '${RESOURCE_GROUP}':"
RESOURCE_COUNT=0

for ITEM in ${PODVM_NAMES}; do
    echo "  Pod VM         ${ITEM}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done

for ITEM in ${NAT_GW_SUBNETS}; do
    echo "  NAT Detach     subnet ${ITEM##*/}"
done

if [ -n "${NAT_GW_ID}" ]; then
    echo "  NAT Gateway    ${NAT_GATEWAY_NAME}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
fi

if [ -n "${NAT_GW_IP_ID}" ]; then
    echo "  Public IP      ${NAT_GATEWAY_IP_NAME} (NAT Gateway)"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
fi

while IFS='|' read -r G_NAME G_DEF G_VER; do
    [ -z "${G_NAME}" ] && continue
    echo "  Image Version  ${G_NAME}/${G_DEF}/${G_VER}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done <<< "${GALLERY_VERSIONS}"

while IFS='|' read -r G_NAME G_DEF; do
    [ -z "${G_NAME}" ] && continue
    echo "  Image Def      ${G_NAME}/${G_DEF}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done <<< "${GALLERY_DEFS}"

for ITEM in ${GALLERY_NAMES}; do
    echo "  Gallery        ${ITEM}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done

if [ -n "${STORAGE_ID}" ]; then
    echo "  Storage Acct   ${PODVM_STORAGE_ACCOUNT}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
fi

for ITEM in ${ROLE_ASSIGNMENT_IDS}; do
    echo "  Role Assign    ${ITEM##*/}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done

if [ -n "${SP_APP_ID}" ]; then
    echo "  Service Princ  ${SP_NAME} (App ID: ${SP_APP_ID})"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
fi

if [ -f "${SP_FILE}" ]; then
    echo "  Local File     ${SP_FILE}"
    RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
fi

if [ "${RESOURCE_COUNT}" -eq 0 ]; then
    echo "  (no CoCo or PeerPods resources found)"
    exit 0
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

# --- Deletion Execution (Dependency Order) ---

# 1. Pod VMs
for ITEM in ${PODVM_NAMES}; do
    echo "Deleting pod VM: ${ITEM}"
    az vm delete --resource-group "${RESOURCE_GROUP}" --name "${ITEM}" --yes \
        --output none || note_failure "pod VM" "${ITEM}"
done

# 2. Detach NAT Gateway from Subnet, then delete NAT Gateway & Public IP
for ITEM in ${NAT_GW_SUBNETS}; do
    echo "Detaching NAT gateway from subnet: ${ITEM##*/}"
    az network vnet subnet update --ids "${ITEM}" --remove natGateway --output none \
        || note_failure "NAT gateway subnet detachment" "${ITEM##*/}"
done

if [ -n "${NAT_GW_ID}" ]; then
    echo "Deleting NAT gateway: ${NAT_GATEWAY_NAME}"
    az network nat gateway delete --ids "${NAT_GW_ID}" --output none \
        || note_failure "NAT gateway" "${NAT_GATEWAY_NAME}"
fi

if [ -n "${NAT_GW_IP_ID}" ]; then
    echo "Deleting public IP: ${NAT_GATEWAY_IP_NAME}"
    az network public-ip delete --ids "${NAT_GW_IP_ID}" --output none \
        || note_failure "public IP" "${NAT_GATEWAY_IP_NAME}"
fi

# 3. Image Versions -> Image Definitions -> Galleries
while IFS='|' read -r G_NAME G_DEF G_VER; do
    [ -z "${G_NAME}" ] && continue
    echo "Deleting image version: ${G_NAME}/${G_DEF}/${G_VER}"
    az sig image-version delete --resource-group "${RESOURCE_GROUP}" \
        --gallery-name "${G_NAME}" --gallery-image-definition "${G_DEF}" \
        --gallery-image-version "${G_VER}" --output none \
        || note_failure "image version" "${G_NAME}/${G_DEF}/${G_VER}"
done <<< "${GALLERY_VERSIONS}"

while IFS='|' read -r G_NAME G_DEF; do
    [ -z "${G_NAME}" ] && continue
    echo "Deleting image definition: ${G_NAME}/${G_DEF}"
    az sig image-definition delete --resource-group "${RESOURCE_GROUP}" \
        --gallery-name "${G_NAME}" --gallery-image-definition "${G_DEF}" \
        --output none || note_failure "image definition" "${G_NAME}/${G_DEF}"
done <<< "${GALLERY_DEFS}"

for ITEM in ${GALLERY_NAMES}; do
    echo "Deleting gallery: ${ITEM}"
    az sig delete --resource-group "${RESOURCE_GROUP}" --gallery-name "${ITEM}" \
        --output none || note_failure "gallery" "${ITEM}"
done

# 4. Storage Account
if [ -n "${STORAGE_ID}" ]; then
    echo "Deleting storage account: ${PODVM_STORAGE_ACCOUNT}"
    az storage account delete --ids "${STORAGE_ID}" --yes --output none \
        || note_failure "storage account" "${PODVM_STORAGE_ACCOUNT}"
fi

# 5. Role Assignments
for ITEM in ${ROLE_ASSIGNMENT_IDS}; do
    echo "Deleting role assignment: ${ITEM##*/}"
    az role assignment delete --ids "${ITEM}" --output none \
        || note_failure "role assignment" "${ITEM##*/}"
done

# 6. Service Principal & Local Credentials File
if [ -n "${SP_APP_ID}" ]; then
    echo "Deleting service principal: ${SP_NAME} (${SP_APP_ID})"
    az ad app delete --id "${SP_APP_ID}" --output none \
        || note_failure "service principal" "${SP_NAME}"
fi

if [ -f "${SP_FILE}" ]; then
    echo "Removing local credential file: ${SP_FILE}"
    rm -f "${SP_FILE}"
fi

echo "------------------------------------------------------"

if [ "${FAILURES}" -gt 0 ]; then
    echo "Teardown finished with ${FAILURES} failure(s)." >&2
    exit 1
fi

echo "CoCo and PeerPods resources teardown complete."
#!/bin/bash

# Creates the RHEL 9 VM that the rest of this folder turns into a CRI-O / Kubernetes /
# Kata development box[cite: 1].
#
# usage: 01_provision_fresh_vm.sh [-c <config-file>] [-s <vm-size>] [-l <region>] [<config-file-or-vm-size>]

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

LOCATION="${LOCATION:-centralindia}"
INSTANCE_NAME="${INSTANCE_NAME:-${RESOURCE_GROUP}-azure-host}"
IMAGE="${IMAGE:-RedHat:RHEL:9-lvm-gen2:latest}"

DEFAULT_VM_SIZE="Standard_D8s_v5"
VM_SIZE="${VM_SIZE:-}"
OS_DISK_SIZE_GB="${OS_DISK_SIZE_GB:-120}"
ADMIN_USER="${ADMIN_USER:-core}"
SSH_KEY_PUB="${SSH_KEY_PUB:-${HOME}/.ssh/id_rsa.pub}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME}"
OUTPUT_FILE="${OUTPUT_DIR}/${INSTANCE_NAME}-external-ip"

# Spot configuration defaults
VM_PRIORITY="${VM_PRIORITY:-Spot}"
EVICTION_POLICY="${EVICTION_POLICY:-Deallocate}"
MAX_PRICE="${MAX_PRICE:--1}"

# --- Main Command Line Option Parsing ---
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--size)      VM_SIZE="$2"; shift 2 ;;
        --size=*)       VM_SIZE="${1#*=}"; shift ;;
        -l|--location)  LOCATION="$2"; shift 2 ;;
        --location=*)   LOCATION="${1#*=}"; shift ;;
        -h|--help)
            echo "usage: $(basename "$0") [-c <config-file>] [-s <vm-size>] [-l <region>] [<vm-size>]"
            echo
            echo "  -c, --config    Path to custom configuration file."
            echo "  -s, --size      VM size (default ${DEFAULT_VM_SIZE})."
            echo "  -l, --location  Azure region (default ${LOCATION})."
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option '$1'." >&2
            exit 2
            ;;
        *)              VM_SIZE="$1"; shift ;;
    esac
done

if [ -z "${VM_SIZE}" ]; then
    VM_SIZE="${DEFAULT_VM_SIZE}"
    echo "No size given; using default ${VM_SIZE}."
fi

# VM Tags
DELETE_AFTER=$(date -u -v+3d +"%Y-%m-%d" 2>/dev/null || date -u -d "+3 days" +"%Y-%m-%d")

VM_TAGS=(
    "owner=${OWNER}"
    "delete-after=${DELETE_AFTER}"
)

# --- Functions ---

write_cloud_init() {
    cat > "$1" <<'CLOUD_CONFIG'
#cloud-config
write_files:
  - path: /usr/local/sbin/grow-rootvg.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/bash
      set -u

      ROOT_SRC=$(findmnt --noheadings --output SOURCE --target /)
      VG=$(lvs --noheadings --options vg_name "${ROOT_SRC}" 2>/dev/null | tr -d '[:space:]')
      if [ -z "${VG}" ]; then
          echo "grow-rootvg: / is not on LVM (${ROOT_SRC}); nothing to do."
          exit 0
      fi

      PV=$(pvs --noheadings --options pv_name --select "vg_name=${VG}" | head -1 | tr -d '[:space:]')
      DISK="/dev/$(lsblk --noheadings --output PKNAME "${PV}" | head -1)"
      PART_NUM="${PV##*[!0-9]}"

      echo "grow-rootvg: growing ${DISK} partition ${PART_NUM} (PV ${PV}, VG ${VG})..."
      growpart "${DISK}" "${PART_NUM}"
      case "$?" in
          0) echo "grow-rootvg: partition grown." ;;
          1) echo "grow-rootvg: partition already fills the disk." ;;
          *) echo "grow-rootvg: ERROR growpart failed."; exit 1 ;;
      esac

      if ! pvresize "${PV}"; then
          echo "grow-rootvg: ERROR pvresize failed."
          exit 1
      fi

      FREE_EXTENTS=$(vgs --noheadings --options vg_free_count "${VG}" | tr -d '[:space:]')
      if [ "${FREE_EXTENTS:-0}" -gt 0 ]; then
          echo "grow-rootvg: extending ${ROOT_SRC} by ${FREE_EXTENTS} free extents..."
          if ! lvextend --resizefs --extents +100%FREE "${ROOT_SRC}"; then
              echo "grow-rootvg: ERROR lvextend failed."
              exit 1
          fi
      else
          echo "grow-rootvg: no free extents in ${VG}; ${ROOT_SRC} already at full size."
      fi

      df -h /
runcmd:
  - [ /usr/local/sbin/grow-rootvg.sh ]
CLOUD_CONFIG
}

# --- Main Logic ---

if ! az account show > /dev/null 2>&1; then
    echo "ERROR: Not authenticated with Azure CLI. Run 'az login' before executing." >&2
    exit 1
fi

if [ ! -f "${SSH_KEY_PUB}" ]; then
    echo "ERROR: SSH public key '${SSH_KEY_PUB}' not found." >&2
    exit 1
fi

echo "Ensuring output directory '${OUTPUT_DIR}' exists..."
mkdir -p "${OUTPUT_DIR}"

# Step 1: Check if Resource Group exists
echo "Checking for resource group '${RESOURCE_GROUP}'..."
if ! az group show --name "${RESOURCE_GROUP}" > /dev/null 2>&1; then
    echo "ERROR: Resource group '${RESOURCE_GROUP}' does not exist." >&2
    exit 1
fi
echo "Resource group '${RESOURCE_GROUP}' found."

# Step 2: Create or start the VM instance
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
    CLOUD_INIT_FILE=$(mktemp -t "${INSTANCE_NAME}-cloud-init.XXXXXX")
    trap 'rm -f "${CLOUD_INIT_FILE}"' EXIT
    write_cloud_init "${CLOUD_INIT_FILE}"

    PRIORITY_FLAGS=()
    if [ "${VM_PRIORITY}" != "Regular" ]; then
        PRIORITY_FLAGS=(
            --priority "${VM_PRIORITY}"
            --eviction-policy "${EVICTION_POLICY}"
            --max-price "${MAX_PRICE}"
        )
    fi

    echo "Creating instance '${INSTANCE_NAME}' (${VM_SIZE}, ${OS_DISK_SIZE_GB}GB) from image '${IMAGE}'..."
    echo "Location: ${LOCATION}."
    echo "Priority: ${VM_PRIORITY} (eviction policy '${EVICTION_POLICY}', max price ${MAX_PRICE})."
    echo "VM will be tagged 'owner=${OWNER}' and 'delete-after=${DELETE_AFTER}'."

    if ! az vm create \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${INSTANCE_NAME}" \
        --location "${LOCATION}" \
        --image "${IMAGE}" \
        --size "${VM_SIZE}" \
        --os-disk-size-gb "${OS_DISK_SIZE_GB}" \
        --admin-username "${ADMIN_USER}" \
        --ssh-key-values "${SSH_KEY_PUB}" \
        --custom-data "${CLOUD_INIT_FILE}" \
        ${PRIORITY_FLAGS[@]+"${PRIORITY_FLAGS[@]}"} \
        ${VM_TAGS[@]+--tags "${VM_TAGS[@]}"} \
        --output none; then
        echo "ERROR: Failed to create instance '${INSTANCE_NAME}'." >&2
        exit 1
    fi
    echo "Instance '${INSTANCE_NAME}' created."
fi

# Step 3: Fetch and save external IP
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
    echo "SSH command: ssh ${ADMIN_USER}@${EXTERNAL_IP}"
else
    echo "ERROR: Could not retrieve external IP address for '${INSTANCE_NAME}'." >&2
    exit 1
fi
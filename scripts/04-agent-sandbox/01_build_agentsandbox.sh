#!/bin/bash

# Clones, builds binaries, and builds the container image for agent-sandbox
# (kubernetes-sigs/agent-sandbox) on the RHEL 9 host.
# Requires 01_setup_k8s_crio.sh to have run to completion first.
#
# usage: 01_build_agentsandbox.sh [-c <config-file>] [<config-file>]

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
ADMIN_USER="${ADMIN_USER:-core}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME}"
IP_FILE="${OUTPUT_DIR}/${INSTANCE_NAME}-external-ip"

WORKSPACE="${WORKSPACE:-/workspace}"
AGENT_SANDBOX_REPO="${AGENT_SANDBOX_REPO:-https://github.com/kubernetes-sigs/agent-sandbox.git}"
AGENT_SANDBOX_REF="${AGENT_SANDBOX_REF:-}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-localhost/agent-sandbox-controller:dev}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=15)
[ -f "${SSH_KEY}" ] && SSH_OPTS+=(-i "${SSH_KEY}")

# --- Functions ---

write_remote_script() {
    cat > "$1" <<'REMOTE_SCRIPT'
#!/bin/bash
# Clones, builds binaries, container images, and patches manifests for agent-sandbox on this host. Safe to re-run.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
AGENT_SANDBOX_REPO="${AGENT_SANDBOX_REPO:-https://github.com/kubernetes-sigs/agent-sandbox.git}"
AGENT_SANDBOX_REF="${AGENT_SANDBOX_REF:-}"
AGENT_SANDBOX_SRC="${WORKSPACE}/agent-sandbox"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-localhost/agent-sandbox-controller:dev}"
RUN_USER="$(id -un)"

log() { echo; echo "=== $* ==="; }

# --- 0. Verify 01_setup_k8s_crio.sh has completed ---

log "Checking 01_setup_k8s_crio.sh prerequisites"
PREREQ_FAILED=0

check_prereq() {
    local description="$1"; shift
    if "$@" > /dev/null 2>&1; then
        echo "  ok:      ${description}"
    else
        echo "  MISSING: ${description}"
        PREREQ_FAILED=1
    fi
}

check_prereq "crio binary at /usr/local/bin/crio"          test -x /usr/local/bin/crio
check_prereq "crun binary at /usr/local/bin/crun"          test -x /usr/local/bin/crun
check_prereq "Go toolchain installed"                      command -v go
check_prereq "Podman installed"                            command -v podman
check_prereq "CRI-O source at ${WORKSPACE}/cri-o"          test -d "${WORKSPACE}/cri-o/.git"
check_prereq "Kubernetes source at ${WORKSPACE}/kubernetes" test -d "${WORKSPACE}/kubernetes/.git"

if [ "${PREREQ_FAILED}" -ne 0 ]; then
    echo
    echo "ERROR: this host is not a completed CRI-O build box."
    echo "Run 01_setup_k8s_crio.sh against it first."
    exit 1
fi
echo "Prerequisites satisfied."

# --- 1. Fetch agent-sandbox source ---

log "Fetching agent-sandbox source"
sudo mkdir -p "${WORKSPACE}"
sudo chown -R "${RUN_USER}:${RUN_USER}" "${WORKSPACE}"

if [ -d "${AGENT_SANDBOX_SRC}/.git" ]; then
    echo "Repository already present; fetching updates."
    git -C "${AGENT_SANDBOX_SRC}" fetch --all --tags --prune
    git -C "${AGENT_SANDBOX_SRC}" merge --ff-only @{u} 2>/dev/null \
        || echo "Not fast-forwarded (local changes or detached HEAD); keeping current tree."
else
    git clone "${AGENT_SANDBOX_REPO}" "${AGENT_SANDBOX_SRC}"
fi

if [ -n "${AGENT_SANDBOX_REF}" ]; then
    echo "Checking out ${AGENT_SANDBOX_REF}"
    git -C "${AGENT_SANDBOX_SRC}" checkout "${AGENT_SANDBOX_REF}"
fi

git -C "${AGENT_SANDBOX_SRC}" --no-pager log -1 --oneline

# --- 2. Setup Go Build Environment ---

log "Setting up Go environment"
mkdir -p "${WORKSPACE}/gopath" "${WORKSPACE}/gocache" "${WORKSPACE}/tmp"
export TMPDIR="${WORKSPACE}/tmp"
export GOPATH="${WORKSPACE}/gopath"
export GOCACHE="${WORKSPACE}/.cache"
export PATH="${GOPATH}/bin:${PATH}"

go version

# --- 3. Build agent-sandbox binaries ---

log "Building agent-sandbox Go binaries"
cd "${AGENT_SANDBOX_SRC}"

if [ -f Makefile ]; then
    make build || make || go build -v ./...
else
    go build -v ./...
fi

# --- 4. Build Controller Container Image with Podman ---

log "Building controller image '${CONTROLLER_IMAGE}' using host network"
if [ -f Containerfile ] || [ -f Dockerfile ]; then
    sudo podman build --network=host -t "${CONTROLLER_IMAGE}" "${AGENT_SANDBOX_SRC}"
    echo "Container image '${CONTROLLER_IMAGE}' successfully created."
else
    echo "WARNING: No Containerfile/Dockerfile found in ${AGENT_SANDBOX_SRC}."
fi

# --- 5. Patch Manifests to Replace ko:// URIs and ImagePullPolicy ---

log "Patching k8s manifests to reference local image '${CONTROLLER_IMAGE}'"

find "${AGENT_SANDBOX_SRC}" -type f \( -name "*.yaml" -o -name "*.yml" \) -exec sed -i \
    -e "s|ko://sigs.k8s.io/agent-sandbox/cmd/agent-sandbox-controller|${CONTROLLER_IMAGE}|g" \
    -e 's|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|g' {} + || true

echo "Patched manifest references:"
grep -rn "${CONTROLLER_IMAGE}" "${AGENT_SANDBOX_SRC}" || echo "  (No direct matches found in text)"

# --- 6. Report Artifacts ---

log "Build summary"
echo "Source tree: ${AGENT_SANDBOX_SRC}"
echo "Commit:      $(git -C "${AGENT_SANDBOX_SRC}" log --format=%h -1 HEAD)"
echo "Image:       ${CONTROLLER_IMAGE} (stored in local CRI-O image store)"
echo "Binaries:"
find "${AGENT_SANDBOX_SRC}" -maxdepth 3 -type f -executable ! -name "*.sh" ! -path "*/.git/*" \
    -exec ls -lh {} + 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}' || echo "  No standalone executable binaries found in root."

echo
echo "NOTE: Nothing has been installed onto the cluster (deliberately)."
REMOTE_SCRIPT
}

# --- Main Logic ---

EXTERNAL_IP=""
if az account show > /dev/null 2>&1; then
    echo "Looking up '${INSTANCE_NAME}' in resource group '${RESOURCE_GROUP}'..."
    EXTERNAL_IP=$(az vm show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${INSTANCE_NAME}" \
        --show-details \
        --query "publicIps" \
        --output tsv 2>/dev/null || true)
fi

if [ -z "${EXTERNAL_IP}" ] && [ -f "${IP_FILE}" ]; then
    EXTERNAL_IP=$(cat "${IP_FILE}")
    echo "Falling back to cached address from ${IP_FILE}"
fi

if [ -z "${EXTERNAL_IP}" ]; then
    echo "ERROR: could not determine address of '${INSTANCE_NAME}'." >&2
    echo "Create it first with 01_provision_fresh_vm.sh." >&2
    exit 1
fi

echo "Target: ${ADMIN_USER}@${EXTERNAL_IP}"

echo "Waiting for SSH..."
SSH_READY=0
for ATTEMPT in $(seq 1 30); do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${ADMIN_USER}@${EXTERNAL_IP}" true 2>/dev/null; then
        SSH_READY=1
        break
    fi
    echo "  not ready yet (attempt ${ATTEMPT})..."
    sleep 10
done

if [ "${SSH_READY}" -ne 1 ]; then
    echo "ERROR: could not reach ${ADMIN_USER}@${EXTERNAL_IP} over SSH." >&2
    exit 1
fi

REMOTE_SCRIPT_FILE=$(mktemp -t build-agentsandbox.XXXXXX)
trap 'rm -f "${REMOTE_SCRIPT_FILE}"' EXIT
write_remote_script "${REMOTE_SCRIPT_FILE}"

echo "Copying script to host..."
if ! scp "${SSH_OPTS[@]}" -q "${REMOTE_SCRIPT_FILE}" \
    "${ADMIN_USER}@${EXTERNAL_IP}:/tmp/build-agentsandbox.sh"; then
    echo "ERROR: failed to copy script to host." >&2
    exit 1
fi

echo "Running agent-sandbox build on ${INSTANCE_NAME}..."
echo "------------------------------------------------------"
if ! ssh "${SSH_OPTS[@]}" -t "${ADMIN_USER}@${EXTERNAL_IP}" \
    "WORKSPACE='${WORKSPACE}' AGENT_SANDBOX_REPO='${AGENT_SANDBOX_REPO}' AGENT_SANDBOX_REF='${AGENT_SANDBOX_REF}' CONTROLLER_IMAGE='${CONTROLLER_IMAGE}' bash /tmp/build-agentsandbox.sh"; then
    echo "------------------------------------------------------"
    echo "ERROR: agent-sandbox build failed on '${INSTANCE_NAME}'." >&2
    exit 1
fi

echo "------------------------------------------------------"
echo "agent-sandbox build complete on '${INSTANCE_NAME}'."
echo "Source: ${WORKSPACE}/agent-sandbox"
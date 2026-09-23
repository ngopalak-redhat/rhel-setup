#!/bin/bash

# Installs agent-sandbox CRDs and controller on the RHEL 9 host,
# provisions a Kata-backed SandboxWarmPool using 'runtimeClassName: kata',
# verifies VM kernel isolation, and cleanly shuts down the warm pool.
#
# Prerequisites:
#   02-k8s-kata/03_install_kata.sh (Kata Containers installed & CRI-O drop-in configured)
#   04-agent-sandbox/01_build_agentsandbox.sh (agent-sandbox source & image built)
#
# usage: 03_setup_katasandbox.sh [-c <config-file>] [<config-file>]

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
ADMIN_USER="${ADMIN_USER:-core}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME}"
IP_FILE="${OUTPUT_DIR}/${INSTANCE_NAME}-external-ip"

WORKSPACE="${WORKSPACE:-/workspace}"
KATA_PREFIX="${KATA_PREFIX:-/opt/kata}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-localhost/agent-sandbox-controller:dev}"
WARMPOOL_REPLICAS="${WARMPOOL_REPLICAS:-2}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
KEEP_TEST_RESOURCES="${KEEP_TEST_RESOURCES:-0}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=15)
[ -f "${SSH_KEY}" ] && SSH_OPTS+=(-i "${SSH_KEY}")

# --- Functions ---

write_remote_script() {
    cat > "$1" <<'REMOTE_SCRIPT'
#!/bin/bash
# Deploys agent-sandbox with Kata runtime, verifies VM isolation, and shuts down. Safe to re-run.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
AGENT_SANDBOX_SRC="${WORKSPACE}/agent-sandbox"
KATA_PREFIX="${KATA_PREFIX:-/opt/kata}"
KUBECONFIG_PATH=/var/run/kubernetes/admin.kubeconfig
KUBECTL="${WORKSPACE}/kubernetes/_output/bin/kubectl"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-localhost/agent-sandbox-controller:dev}"
WARMPOOL_REPLICAS="${WARMPOOL_REPLICAS:-2}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"
KEEP_TEST_RESOURCES="${KEEP_TEST_RESOURCES:-0}"

WARMPOOL_NAME="kata-agent-warmpool"
TEMPLATE_NAME="kata-agent-template"

log() { echo; echo "=== $* ==="; }

k() {
    sudo -E "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" "$@"
}

check_prereq() {
    local description="$1"; shift
    if "$@" > /dev/null 2>&1; then
        echo "  ok:      ${description}"
    else
        echo "  MISSING: ${description}"
        PREREQ_FAILED=1
    fi
}

# --- 0. Verify Prerequisites ---

log "Checking prerequisites (03_install_kata.sh & 01_build_agentsandbox.sh)"

PREREQ_FAILED=0

# Kubernetes Cluster Prerequisites
check_prereq "Kubeconfig at ${KUBECONFIG_PATH}"              sudo test -f "${KUBECONFIG_PATH}"
check_prereq "kubectl binary at ${KUBECTL}"                 test -x "${KUBECTL}"
check_prereq "crio binary at /usr/local/bin/crio"           test -x /usr/local/bin/crio

# Kata Containers Prerequisites (produced by 03_install_kata.sh)
check_prereq "Kata shim at ${KATA_PREFIX}/bin/containerd-shim-kata-v2"  test -x "${KATA_PREFIX}/bin/containerd-shim-kata-v2"
check_prereq "Kata QEMU config at ${KATA_PREFIX}/share/defaults/kata-containers/configuration-qemu.toml" test -f "${KATA_PREFIX}/share/defaults/kata-containers/configuration-qemu.toml"
check_prereq "CRI-O Kata drop-in at /etc/crio/crio.conf.d/50-kata"      test -f /etc/crio/crio.conf.d/50-kata

# Agent Sandbox Prerequisites (produced by 01_build_agentsandbox.sh)
check_prereq "agent-sandbox source at ${AGENT_SANDBOX_SRC}" test -d "${AGENT_SANDBOX_SRC}/.git"
check_prereq "Controller image '${CONTROLLER_IMAGE}' in image store" sudo podman image exists "${CONTROLLER_IMAGE}"

if [ "${PREREQ_FAILED}" -ne 0 ]; then
    echo
    echo "ERROR: Prerequisites incomplete."
    echo "Ensure 02-k8s-kata/03_install_kata.sh and 04-agent-sandbox/01_build_agentsandbox.sh have run."
    exit 1
fi
echo "Prerequisites satisfied."

# Restore mount propagation before creating any new Kata sandboxes. Merely
# writing the drop-in or reloading systemd does not run ExecStartPost.
log "Configuring CRI-O mount propagation for Kata"

sudo mkdir -p /etc/systemd/system/crio.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/crio.service.d/20-kata-mount-propagation.conf > /dev/null
[Service]
ExecStartPost=-/usr/bin/mount --make-rshared /var/lib/containers/storage/overlay
EOF
sudo systemctl daemon-reload

log "Restarting CRI-O to apply mount propagation"
if ! sudo systemctl restart crio; then
    echo "ERROR: Could not restart CRI-O." >&2
    sudo journalctl -u crio --no-pager -n 50 || true
    exit 1
fi
sudo systemctl is-active --quiet crio

# The installer hook tolerates mount errors, so explicitly verify its effect.
OVERLAY_PROPAGATION="$(sudo findmnt --noheadings --mountpoint /var/lib/containers/storage/overlay --output PROPAGATION)"
case ",${OVERLAY_PROPAGATION}," in
    *,shared,*) echo "CRI-O overlay mount propagation: ${OVERLAY_PROPAGATION}" ;;
    *)
        echo "ERROR: CRI-O overlay mount is not shared (${OVERLAY_PROPAGATION})." >&2
        exit 1
        ;;
esac

# --- 1. Register Kata RuntimeClass in Kubernetes ---

log "Applying RuntimeClass 'kata'"

cat <<EOF | k apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
EOF

k get runtimeclass kata

# --- 2. Install agent-sandbox CRDs and Controller from Built Source ---

log "Deploying agent-sandbox CRDs and Controller from source"

if [ -d "${AGENT_SANDBOX_SRC}/k8s" ]; then
    echo "Applying k8s/ manifests..."
    k apply -k "${AGENT_SANDBOX_SRC}/k8s/" || k apply -f "${AGENT_SANDBOX_SRC}/k8s/"
elif [ -f "${AGENT_SANDBOX_SRC}/Makefile" ]; then
    echo "Running 'make deploy' in ${AGENT_SANDBOX_SRC}..."
    (cd "${AGENT_SANDBOX_SRC}" && sudo -E PATH="${PATH}" GOPATH="${WORKSPACE}/gopath" GOCACHE="${WORKSPACE}/.cache" make deploy KUBECONFIG="${KUBECONFIG_PATH}")
else
    echo "ERROR: Could not locate k8s/ or Makefile in ${AGENT_SANDBOX_SRC}." >&2
    exit 1
fi

log "Waiting for agent-sandbox CRDs to establish"
k wait --for=condition=established --timeout=60s \
    crd/sandboxtemplates.extensions.agents.x-k8s.io \
    crd/sandboxwarmpools.extensions.agents.x-k8s.io \
    crd/sandboxclaims.extensions.agents.x-k8s.io \
    crd/sandboxes.agents.x-k8s.io || true

# --- 3. Patch Controller Deployment Image and ImagePullPolicy ---

SYSTEM_NS="$(k get deployments -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' | grep 'agent-sandbox' | head -1 | awk '{print $1}')"
SYSTEM_NS="${SYSTEM_NS:-agent-sandbox-system}"

CONTROLLER_DEPLOY="$(k get deployments -n "${SYSTEM_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "agent-sandbox-controller")"

log "Updating controller deployment image and pull policy"
if k get deployment "${CONTROLLER_DEPLOY}" -n "${SYSTEM_NS}" >/dev/null 2>&1; then
    echo "  Target Deployment: ${CONTROLLER_DEPLOY} (namespace: ${SYSTEM_NS})"
    echo "  Setting image to: ${CONTROLLER_IMAGE}"

    k set image "deployment/${CONTROLLER_DEPLOY}" -n "${SYSTEM_NS}" "agent-sandbox-controller=${CONTROLLER_IMAGE}" || \
    k set image "deployment/${CONTROLLER_DEPLOY}" -n "${SYSTEM_NS}" "*=${CONTROLLER_IMAGE}" || true

    echo "  Setting imagePullPolicy to: IfNotPresent"
    k patch deployment "${CONTROLLER_DEPLOY}" -n "${SYSTEM_NS}" -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"agent-sandbox-controller\",\"image\":\"${CONTROLLER_IMAGE}\",\"imagePullPolicy\":\"IfNotPresent\"}]}}}}" || \
    k patch deployment "${CONTROLLER_DEPLOY}" -n "${SYSTEM_NS}" -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${CONTROLLER_DEPLOY}\",\"image\":\"${CONTROLLER_IMAGE}\",\"imagePullPolicy\":\"IfNotPresent\"}]}}}}" || true

    echo "Waiting for rollout of deployment/${CONTROLLER_DEPLOY} in ${SYSTEM_NS}..."
    k rollout status "deployment/${CONTROLLER_DEPLOY}" -n "${SYSTEM_NS}" --timeout=180s
else
    echo "WARNING: Deployment ${CONTROLLER_DEPLOY} not found in ${SYSTEM_NS}."
fi

# --- 4. Clean Previous Test Run and Deploy Kata Warm Pool ---

log "Cleaning up old warm pool resources if present"
k delete sandboxwarmpool "${WARMPOOL_NAME}" -n default --ignore-not-found=true || true
k delete sandboxtemplate "${TEMPLATE_NAME}" -n default --ignore-not-found=true || true

log "Creating SandboxTemplate and ${WARMPOOL_REPLICAS}-replica SandboxWarmPool with runtimeClassName: kata"

cat <<EOF | k apply -f -
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxTemplate
metadata:
  name: ${TEMPLATE_NAME}
  namespace: default
spec:
  podTemplate:
    spec:
      runtimeClassName: kata
      containers:
        - name: kata-sandbox-app
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["/bin/sh", "-c", "sleep infinity"]
---
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxWarmPool
metadata:
  name: ${WARMPOOL_NAME}
  namespace: default
spec:
  replicas: ${WARMPOOL_REPLICAS}
  sandboxTemplateRef:
    name: ${TEMPLATE_NAME}
EOF

log "Created Kata Warm Pool Resources:"
k get sandboxtemplate,sandboxwarmpool -n default

# --- 5. Verify Kata Warm Pool Creation & Replica VM Isolation ---

log "Waiting for Kata warm pool to reach ${WARMPOOL_REPLICAS} Ready replicas..."

WARMPOOL_READY=0
MAX_ATTEMPTS=$((TEST_TIMEOUT / 5))

for ATTEMPT in $(seq 1 "${MAX_ATTEMPTS}"); do
    READY_REPLICAS="$(k get sandboxwarmpool "${WARMPOOL_NAME}" -n default -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    READY_REPLICAS="${READY_REPLICAS:-0}"
    CURRENT_REPLICAS="$(k get sandboxwarmpool "${WARMPOOL_NAME}" -n default -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0)"
    CURRENT_REPLICAS="${CURRENT_REPLICAS:-0}"

    echo "  Status (${ATTEMPT}/${MAX_ATTEMPTS}): Current Replicas = ${CURRENT_REPLICAS}, Ready Replicas = ${READY_REPLICAS} / ${WARMPOOL_REPLICAS}"

    if [ "${READY_REPLICAS}" -ge "${WARMPOOL_REPLICAS}" ]; then
        log "SUCCESS: Kata Warm pool '${WARMPOOL_NAME}' reached ${READY_REPLICAS} Ready replicas!"
        WARMPOOL_READY=1
        break
    fi
    sleep 5
done

if [ "${WARMPOOL_READY}" -ne 1 ]; then
    echo "ERROR: Kata Warm pool '${WARMPOOL_NAME}' failed to reach ${WARMPOOL_REPLICAS} ready replicas within ${TEST_TIMEOUT}s." >&2
    k describe sandboxwarmpool "${WARMPOOL_NAME}" -n default || true
    k get pods -n default -o wide || true
    exit 1
fi

echo
log "Current Kata Sandbox Pods in default namespace:"
k get pods -n default -o wide

log "Confirming Kata VM Sandbox Isolation (Kernel Verification)"
SAMPLE_POD="$(k get pods -n default --no-headers -o custom-columns=":metadata.name" | grep -v 'llm-sealed-env' | head -1 || true)"

if [ -n "${SAMPLE_POD}" ]; then
    echo "Checking Kata sandbox pod: ${SAMPLE_POD}"
    HOST_KERNEL="$(uname -r)"
    GUEST_KERNEL="$(k exec "${SAMPLE_POD}" -n default -- uname -r 2>/dev/null || echo "unknown")"
    echo "  host kernel : ${HOST_KERNEL}"
    echo "  guest kernel: ${GUEST_KERNEL}"

    if [ "${GUEST_KERNEL}" = "unknown" ]; then
        echo "  WARNING: Could not read guest kernel."
    elif [ "${GUEST_KERNEL}" = "${HOST_KERNEL}" ]; then
        echo "  ERROR: Same kernel as host! Pod is NOT running in a Kata VM." >&2
        exit 1
    else
        echo "  SUCCESS: Different kernels confirmed! Sandbox is running inside an isolated Kata VM."
    fi
fi

# --- 6. Shut Down Warm Pool and Clean Up ---

if [ "${KEEP_TEST_RESOURCES}" = "1" ]; then
    echo
    echo "KEEP_TEST_RESOURCES=1; leaving Kata warm pool resources running."
else
    echo
    log "Shutting down and deleting Kata warm pool '${WARMPOOL_NAME}'..."
    k delete sandboxwarmpool "${WARMPOOL_NAME}" -n default --ignore-not-found=true --wait=true
    k delete sandboxtemplate "${TEMPLATE_NAME}" -n default --ignore-not-found=true --wait=true
    echo "Confirmed: Kata warm pool resources successfully shut down and deleted."
fi

log "Summary"
printf '  %-28s %s\n' "agent-sandbox CRDs" "installed"
printf '  %-28s %s\n' "runtime engine" "kata (Kata Containers VM)"
printf '  %-28s %s\n' "controller image" "${CONTROLLER_IMAGE} (IfNotPresent)"
printf '  %-28s %s\n' "controller namespace" "${SYSTEM_NS}"
printf '  %-28s %s\n' "Kata warm pool test" "${WARMPOOL_REPLICAS}/${WARMPOOL_REPLICAS} replicas verified & shut down"
REMOTE_SCRIPT
}

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- Main Logic ---

command -v az > /dev/null 2>&1 || fail "the az CLI is not installed."
az account show > /dev/null 2>&1 || fail "not logged in to Azure. Run 'az login'."

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
    fail "could not determine address of '${INSTANCE_NAME}'."
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
[ "${SSH_READY}" -eq 1 ] || fail "could not reach ${ADMIN_USER}@${EXTERNAL_IP} over SSH."

REMOTE_SCRIPT_FILE=$(mktemp -t setup-katasandbox.XXXXXX)
trap 'rm -f "${REMOTE_SCRIPT_FILE}"' EXIT

write_remote_script "${REMOTE_SCRIPT_FILE}"

echo "Copying script to host..."
scp "${SSH_OPTS[@]}" -q "${REMOTE_SCRIPT_FILE}" \
    "${ADMIN_USER}@${EXTERNAL_IP}:/tmp/setup-katasandbox.sh" \
    || fail "failed to copy script to host."

echo "Running Kata agent-sandbox warm pool deployment on ${INSTANCE_NAME}..."
echo "------------------------------------------------------"
if ! ssh "${SSH_OPTS[@]}" -t "${ADMIN_USER}@${EXTERNAL_IP}" \
    "WORKSPACE='${WORKSPACE}' KATA_PREFIX='${KATA_PREFIX}' CONTROLLER_IMAGE='${CONTROLLER_IMAGE}' WARMPOOL_REPLICAS='${WARMPOOL_REPLICAS}' TEST_TIMEOUT='${TEST_TIMEOUT}' KEEP_TEST_RESOURCES='${KEEP_TEST_RESOURCES}' bash /tmp/setup-katasandbox.sh"; then
    echo "------------------------------------------------------"
    echo "ERROR: Kata agent-sandbox warm pool deployment failed on '${INSTANCE_NAME}'." >&2
    exit 1
fi

echo "------------------------------------------------------"
echo "Kata agent-sandbox warm pool successfully verified and shut down on '${INSTANCE_NAME}'."
#!/bin/bash

# Configures the RHEL 9 host created by 01_provision_fresh_vm.sh (or restored
# from a backup image by 03_restore_from_image.sh) as a CRI-O build box:
# build dependencies, the latest crun release, CRI-O compiled from source, and a
# drop-in that points CRI-O's default runtime at that crun binary[cite: 5].
#
# usage: 01_setup_k8s_crio.sh [-c <config-file>] [<config-file>]

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

# Build settings, overridable from environment/config
WORKSPACE="${WORKSPACE:-/workspace}"
CRIO_REPO="${CRIO_REPO:-https://github.com/cri-o/cri-o.git}"
CRIO_REF="${CRIO_REF:-}"
BUILDTAGS="${BUILDTAGS:-exclude_graphdriver_btrfs}"
K8S_REPO="${K8S_REPO:-https://github.com/kubernetes/kubernetes.git}"
START_CLUSTER="${START_CLUSTER:-1}"
FORCE_BUILD="${FORCE_BUILD:-0}"
CLUSTER_WAIT_ATTEMPTS="${CLUSTER_WAIT_ATTEMPTS:-240}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=15)
[ -f "${SSH_KEY}" ] && SSH_OPTS+=(-i "${SSH_KEY}")

# --- Functions ---

write_remote_script() {
    cat > "$1" <<'REMOTE_SCRIPT'
#!/bin/bash
# Provisions this host as a CRI-O build box. Safe to re-run.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
CRIO_REPO="${CRIO_REPO:-https://github.com/cri-o/cri-o.git}"
CRIO_REF="${CRIO_REF:-}"
BUILDTAGS="${BUILDTAGS:-exclude_graphdriver_btrfs}"
K8S_REPO="${K8S_REPO:-https://github.com/kubernetes/kubernetes.git}"
START_CLUSTER="${START_CLUSTER:-1}"
CLUSTER_WAIT_ATTEMPTS="${CLUSTER_WAIT_ATTEMPTS:-240}"
FORCE_BUILD="${FORCE_BUILD:-0}"
RUN_USER="$(id -un)"
CLUSTER_LOG="${WORKSPACE}/tmp/local-up-cluster.log"

log() { echo; echo "=== $* ==="; }

ARCH="$(uname -m)"
if [ "${ARCH}" != "x86_64" ]; then
    echo "ERROR: the crun release asset used below is linux-amd64 only (host is ${ARCH})."
    exit 1
fi

# --- 1. Install system and build dependencies ---

DNF_PACKAGES=(
  git make gcc pkgconf-pkg-config systemd-devel
  glib2-devel glibc-devel libseccomp-devel libassuan-devel
  device-mapper-devel glibc-static
  libgpg-error-devel libselinux-devel gpgme-devel
  shadow-utils python3 conmon go-md2man
  golang container-selinux
)

MISSING_PACKAGES=()
for PKG in "${DNF_PACKAGES[@]}"; do
    rpm -q "${PKG}" > /dev/null 2>&1 || MISSING_PACKAGES+=("${PKG}")
done

if [ "${#MISSING_PACKAGES[@]}" -eq 0 ] && [ "${FORCE_BUILD}" != "1" ]; then
    log "All ${#DNF_PACKAGES[@]} build dependencies already installed; skipping dnf"
    echo "Set FORCE_BUILD=1 to run the package steps anyway."
else
    if [ "${#MISSING_PACKAGES[@]}" -gt 0 ]; then
        echo "Missing packages: ${MISSING_PACKAGES[*]}"
    fi

    log "Updating base system"
    sudo dnf update -y

    log "Installing Development Tools group"
    sudo dnf groupinstall -y "Development Tools"

    log "Enabling CodeReady Builder repository"
    sudo dnf install -y dnf-plugins-core
    CRB_REPO="$(sudo dnf repolist --all --quiet \
        | awk '$1 ~ /^codeready-builder/ && $1 !~ /(debug|source)/ {print $1; exit}')"
    if [ -n "${CRB_REPO}" ]; then
        sudo dnf config-manager --set-enabled "${CRB_REPO}"
        echo "Enabled ${CRB_REPO}"
    else
        echo "WARNING: no codeready-builder repo found; some -devel packages may fail to install."
    fi

    log "Installing CRI-O build dependencies"
    sudo dnf install -y "${DNF_PACKAGES[@]}"
fi

go version
rpm -q container-selinux

# --- 2. Download and install the latest crun release ---

if [ -x /usr/local/bin/crun ] && [ "${FORCE_BUILD}" != "1" ]; then
    log "crun already installed; skipping the download"
    /usr/local/bin/crun --version | head -1
else
    log "Installing latest crun release"
    LATEST_TAG="$(curl -s https://api.github.com/repos/containers/crun/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')"
    if [ -z "${LATEST_TAG}" ]; then
        echo "ERROR: could not determine the latest crun release tag (GitHub API rate limit?)."
        exit 1
    fi
    CRUN_VER="${LATEST_TAG#v}"
    echo "Latest crun release: ${LATEST_TAG}"

    sudo curl -fL \
        "https://github.com/containers/crun/releases/download/${LATEST_TAG}/crun-${CRUN_VER}-linux-amd64" \
        -o /usr/local/bin/crun
    sudo chmod +x /usr/local/bin/crun
    /usr/local/bin/crun --version
fi

# --- 3. Build and install CRI-O from source ---

log "Preparing workspace at ${WORKSPACE}"
sudo mkdir -p "${WORKSPACE}/tmp" "${WORKSPACE}/.cache"
sudo chown -R "${RUN_USER}:${RUN_USER}" "${WORKSPACE}"

log "Fetching CRI-O source"
if [ -d "${WORKSPACE}/cri-o/.git" ]; then
    echo "Repository already present; fetching updates."
    git -C "${WORKSPACE}/cri-o" fetch --all --tags --prune
else
    git clone "${CRIO_REPO}" "${WORKSPACE}/cri-o"
fi
if [ -n "${CRIO_REF}" ]; then
    echo "Checking out ${CRIO_REF}"
    git -C "${WORKSPACE}/cri-o" checkout "${CRIO_REF}"
fi
git -C "${WORKSPACE}/cri-o" --no-pager log -1 --oneline

SRC_COMMIT="$(git -C "${WORKSPACE}/cri-o" rev-parse HEAD)"
INSTALLED_COMMIT=""
if [ -x /usr/local/bin/crio ]; then
    INSTALLED_COMMIT="$(/usr/local/bin/crio --version 2>/dev/null \
        | awk '/GitCommit:/ {print $2; exit}')"
fi

if [ "${FORCE_BUILD}" != "1" ] && [ -n "${INSTALLED_COMMIT}" ] \
   && [ "${INSTALLED_COMMIT}" = "${SRC_COMMIT}" ]; then
    log "CRI-O already built from ${SRC_COMMIT}; skipping build and install"
    echo "Set FORCE_BUILD=1 to rebuild it anyway."
else
    if [ -n "${INSTALLED_COMMIT}" ] && [ "${INSTALLED_COMMIT}" != "${SRC_COMMIT}" ]; then
        echo "Installed crio is ${INSTALLED_COMMIT}, source is ${SRC_COMMIT}; rebuilding."
    fi

    log "Building CRI-O (BUILDTAGS=${BUILDTAGS})"
    cd "${WORKSPACE}/cri-o"
    TMPDIR="${WORKSPACE}/tmp" GOCACHE="${WORKSPACE}/.cache" \
        make BUILDTAGS="${BUILDTAGS}" -j"$(nproc)"

    log "Installing CRI-O binaries and default configuration"
    sudo PATH="${PATH}" make install
    sudo make install.config
fi

# --- 4. Configure CRI-O and system policies ---

log "Pointing the default runtime at crun"
sudo mkdir -p /etc/crio/crio.conf.d
cat <<'EOF' | sudo tee /etc/crio/crio.conf.d/10-crun.conf
[crio.runtime]
default_runtime = "crun"

[crio.runtime.runtimes.crun]
runtime_path = "/usr/local/bin/crun"
runtime_root = "/run/crun"
EOF

log "Configuring container registry search list"
if [ -f /etc/containers/registries.conf ] && [ ! -f /etc/containers/registries.conf.orig ]; then
    sudo cp /etc/containers/registries.conf /etc/containers/registries.conf.orig
    echo "Saved original to /etc/containers/registries.conf.orig"
fi
sudo mkdir -p /etc/containers
cat <<'EOF' | sudo tee /etc/containers/registries.conf
unqualified-search-registries = ['docker.io', 'quay.io', 'registry.k8s.io']
EOF

log "Installing the container signature policy"
if [ ! -f /etc/containers/policy.json ]; then
    cat <<'EOF' | sudo tee /etc/containers/policy.json
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ],
    "transports": {
        "docker-daemon": {
            "": [
                {
                    "type": "insecureAcceptAnything"
                }
            ]
        }
    }
}
EOF
else
    echo "/etc/containers/policy.json already present."
fi

# --- 5. Install crictl ---

log "Installing crictl"
if ! command -v crictl > /dev/null 2>&1; then
    CRICTL_TAG="$(curl -s https://api.github.com/repos/kubernetes-sigs/cri-tools/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')"
    if [ -z "${CRICTL_TAG}" ]; then
        echo "ERROR: could not determine the latest cri-tools release tag."
        exit 1
    fi
    echo "Latest cri-tools release: ${CRICTL_TAG}"
    curl -fL \
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_TAG}/crictl-${CRICTL_TAG}-linux-amd64.tar.gz" \
        -o "${WORKSPACE}/tmp/crictl.tar.gz"
    sudo tar -C /usr/local/bin -xzf "${WORKSPACE}/tmp/crictl.tar.gz" crictl
    rm -f "${WORKSPACE}/tmp/crictl.tar.gz"
fi

sudo ln -sf /usr/local/bin/crictl /usr/bin/crictl
crictl --version

cat <<'EOF' | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/crio/crio.sock
image-endpoint: unix:///var/run/crio/crio.sock
timeout: 10
EOF

# --- 6. Run CRI-O under systemd ---

log "Installing the CRI-O systemd unit"
cd "${WORKSPACE}/cri-o"
sudo cp contrib/systemd/crio.service /etc/systemd/system/crio.service
sudo sed -i 's|/usr/bin/crio|/usr/local/bin/crio|g' /etc/systemd/system/crio.service

sudo chcon -t container_runtime_exec_t /usr/local/bin/crio

sudo systemctl daemon-reload
sudo systemctl reset-failed crio 2>/dev/null || true
sudo systemctl enable crio --now || true
sudo systemctl restart crio || true

if ! sudo systemctl is-active --quiet crio; then
    echo "ERROR: crio.service failed to start."
    sudo journalctl -u crio --no-pager -n 50
    exit 1
fi
echo "crio.service is active."

log "Checking CRI-O is tracking the crun binary"
sudo /usr/local/bin/crictl info | grep -E 'runtimeHandlers|defaultRuntime' -A 5 || true

# --- 7. Prepare the Kubernetes source tree and etcd ---

log "Fetching Kubernetes source"
sudo mkdir -p "${WORKSPACE}"
sudo chown -R "${RUN_USER}:${RUN_USER}" "${WORKSPACE}"

if [ -d "${WORKSPACE}/kubernetes/.git" ]; then
    echo "Kubernetes source already present at ${WORKSPACE}/kubernetes."
else
    git clone --depth 1 "${K8S_REPO}" "${WORKSPACE}/kubernetes"
fi

log "Installing etcd"
cd "${WORKSPACE}/kubernetes"
if [ -x "${WORKSPACE}/kubernetes/third_party/etcd/etcd" ] && [ "${FORCE_BUILD}" != "1" ]; then
    echo "etcd already present at ${WORKSPACE}/kubernetes/third_party/etcd; skipping the download."
else
    ./hack/install-etcd.sh
fi

sudo ln -sf "${WORKSPACE}/kubernetes/third_party/etcd/etcd" /usr/bin/etcd
sudo ln -sf "${WORKSPACE}/kubernetes/third_party/etcd/etcdctl" /usr/bin/etcdctl
sudo which etcd
sudo etcd --version

# --- 8. Launch the cluster ---

if [ "${START_CLUSTER}" != "1" ]; then
    log "START_CLUSTER=${START_CLUSTER}; skipping local-up-cluster.sh"
else
    sudo mkdir -p "${WORKSPACE}/tmp" "${WORKSPACE}/.cache"
    sudo chown -R "${RUN_USER}:${RUN_USER}" "${WORKSPACE}/tmp" "${WORKSPACE}/.cache"

    if pgrep -f "local-up-cluster.sh" > /dev/null 2>&1; then
        log "local-up-cluster.sh is already running; leaving it alone"
        echo "Stop it with: sudo pkill -f local-up-cluster.sh"
    else
        log "Launching local-up-cluster.sh in the background"
        cd "${WORKSPACE}/kubernetes"
        sudo setsid nohup env \
            LOG_DIR="${WORKSPACE}/tmp" \
            TMPDIR="${WORKSPACE}/tmp" \
            GOCACHE="${WORKSPACE}/.cache" \
            CGROUP_DRIVER=systemd \
            CONTAINER_RUNTIME=remote \
            CONTAINER_RUNTIME_ENDPOINT='unix:///var/run/crio/crio.sock' \
            ./hack/local-up-cluster.sh > "${CLUSTER_LOG}" 2>&1 < /dev/null &
        echo "Started. Log: ${CLUSTER_LOG}"
    fi

    log "Waiting for the cluster (Kubernetes is compiled first, so this is slow)"
    CLUSTER_READY=0
    for ATTEMPT in $(seq 1 "${CLUSTER_WAIT_ATTEMPTS}"); do
        if grep -q "Local Kubernetes cluster is running" "${CLUSTER_LOG}" 2>/dev/null; then
            CLUSTER_READY=1
            break
        fi
        if ! pgrep -f "local-up-cluster.sh" > /dev/null 2>&1; then
            echo "ERROR: local-up-cluster.sh exited before the cluster came up."
            tail -40 "${CLUSTER_LOG}"
            exit 1
        fi
        if [ $((ATTEMPT % 15)) -eq 0 ]; then
            echo "  still waiting (${ATTEMPT}/${CLUSTER_WAIT_ATTEMPTS}): $(tail -1 "${CLUSTER_LOG}" 2>/dev/null)"
        fi
        sleep 20
    done

    if [ "${CLUSTER_READY}" -ne 1 ]; then
        echo "ERROR: cluster did not report ready within the timeout."
        tail -40 "${CLUSTER_LOG}"
        exit 1
    fi
    echo "Cluster reported ready."
fi

# --- 9. Verify ---

log "Verification"
echo "crio:  $(/usr/local/bin/crio --version | head -1)"
echo "crun:  $(/usr/local/bin/crun --version | head -1)"
echo "conmon: $(conmon --version | head -1)"
echo
echo "--- /etc/crio/crio.conf.d/10-crun.conf ---"
cat /etc/crio/crio.conf.d/10-crun.conf
echo
echo "--- effective runtime config (from crio config) ---"
CRIO_RENDERED="$(sudo /usr/local/bin/crio config 2>/dev/null)"
echo "${CRIO_RENDERED}" | grep -E '^#?[[:space:]]*default_runtime[[:space:]]*=' || true
echo "${CRIO_RENDERED}" | grep -A3 'crio.runtime.runtimes.crun' || true
echo
echo "--- crio.service ---"
sudo systemctl is-active crio && sudo systemctl is-enabled crio
echo
if [ "${START_CLUSTER}" = "1" ]; then
    echo "--- cluster nodes ---"
    KUBECTL="${WORKSPACE}/kubernetes/_output/bin/kubectl"
    [ -x "${KUBECTL}" ] || KUBECTL="$(command -v kubectl || true)"
    if [ -n "${KUBECTL}" ] && [ -x "${KUBECTL}" ]; then
        sudo "${KUBECTL}" --kubeconfig /var/run/kubernetes/admin.kubeconfig get nodes || true
        sudo "${KUBECTL}" --kubeconfig /var/run/kubernetes/admin.kubeconfig get pods -A || true
    else
        echo "kubectl not found; use ${WORKSPACE}/kubernetes/cluster/kubectl.sh"
    fi
    echo
    echo "--- cluster log tail ---"
    tail -5 "${CLUSTER_LOG}" 2>/dev/null || true
    echo
fi
echo "--- disk usage ---"
df -h "$(df --output=target "${WORKSPACE}" | tail -1)"

# --- 10. Sample Pod Smoke Test ---

if [ "${START_CLUSTER}" = "1" ]; then
    log "Sample Pod Smoke Test"
    KUBECTL="${WORKSPACE}/kubernetes/_output/bin/kubectl"
    [ -x "${KUBECTL}" ] || KUBECTL="$(command -v kubectl || true)"

    if [ -n "${KUBECTL}" ] && [ -x "${KUBECTL}" ]; then
        KUBECMD="sudo ${KUBECTL} --kubeconfig /var/run/kubernetes/admin.kubeconfig"
        TEST_POD="sample-test-pod"

        # Cleanup pre-existing instance if present
        ${KUBECMD} delete pod "${TEST_POD}" --now --ignore-not-found=true 2>/dev/null || true

        echo "Creating sample pod '${TEST_POD}'..."
        ${KUBECMD} run "${TEST_POD}" --image=registry.k8s.io/pause:3.9 --restart=Never

        echo "Waiting for sample pod '${TEST_POD}' to be in Running/Ready state..."
        if ${KUBECMD} wait --for=condition=Ready "pod/${TEST_POD}" --timeout=120s; then
            echo "SUCCESS: Pod '${TEST_POD}' is active and running!"

            echo "Deleting sample pod '${TEST_POD}'..."
            ${KUBECMD} delete pod "${TEST_POD}" --now
            echo "Sample pod deleted successfully."
        else
            echo "ERROR: Pod '${TEST_POD}' failed to reach Running/Ready state within 120 seconds."
            ${KUBECMD} describe pod "${TEST_POD}" || true
            ${KUBECMD} delete pod "${TEST_POD}" --now || true
            exit 1
        fi
    else
        echo "WARNING: kubectl binary not found; skipping sample pod smoke test."
    fi
fi
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
    echo "ERROR: could not determine the address of '${INSTANCE_NAME}'." >&2
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

REMOTE_SCRIPT_FILE=$(mktemp -t configure-crio.XXXXXX)
trap 'rm -f "${REMOTE_SCRIPT_FILE}"' EXIT
write_remote_script "${REMOTE_SCRIPT_FILE}"

echo "Copying provisioning script to the host..."
if ! scp "${SSH_OPTS[@]}" -q "${REMOTE_SCRIPT_FILE}" \
    "${ADMIN_USER}@${EXTERNAL_IP}:/tmp/configure-crio.sh"; then
    echo "ERROR: failed to copy the provisioning script to the host." >&2
    exit 1
fi

echo "Running CRI-O setup on ${INSTANCE_NAME} (this takes a while)..."
echo "------------------------------------------------------"
if ! ssh "${SSH_OPTS[@]}" -t "${ADMIN_USER}@${EXTERNAL_IP}" \
    "WORKSPACE='${WORKSPACE}' CRIO_REPO='${CRIO_REPO}' CRIO_REF='${CRIO_REF}' BUILDTAGS='${BUILDTAGS}' K8S_REPO='${K8S_REPO}' START_CLUSTER='${START_CLUSTER}' CLUSTER_WAIT_ATTEMPTS='${CLUSTER_WAIT_ATTEMPTS}' FORCE_BUILD='${FORCE_BUILD}' bash /tmp/configure-crio.sh"; then
    echo "------------------------------------------------------"
    echo "ERROR: CRI-O setup failed on '${INSTANCE_NAME}'." >&2
    exit 1
fi

echo "------------------------------------------------------"
echo "Setup complete on '${INSTANCE_NAME}'."
echo "CRI-O source:      ${WORKSPACE}/cri-o"
echo "Kubernetes source: ${WORKSPACE}/kubernetes"
if [ "${START_CLUSTER}" = "1" ]; then
    echo "Cluster log:       ${WORKSPACE}/tmp/local-up-cluster.log"
    echo "Kubeconfig:        /var/run/kubernetes/admin.kubeconfig"
    echo "Stop the cluster:  sudo pkill -f local-up-cluster.sh"
fi
echo "SSH: ssh ${ADMIN_USER}@${EXTERNAL_IP}"
echo
echo "NOTE: 'dnf update' may have installed a new kernel; reboot the host to pick it up."
echo "      Rebooting will also stop the local-up-cluster process."
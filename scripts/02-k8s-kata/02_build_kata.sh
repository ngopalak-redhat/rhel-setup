#!/bin/bash

# Installs Kata Containers on the RHEL 9 host already configured as a CRI-O build box
# by 01_setup_k8s_crio.sh.
#
# usage: 02_build_kata.sh [-c <config-file>] [<config-file>]

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

# Kata build settings, overridable from environment/config
KATA_REPO="${KATA_REPO:-https://github.com/kata-containers/kata-containers.git}"
KATA_REF="${KATA_REF:-}"
KATA_DISTRO="${KATA_DISTRO:-ubuntu}"
KATA_OS_VERSION="${KATA_OS_VERSION:-}"
KATA_ENGINE_RUNTIME="${KATA_ENGINE_RUNTIME:-crun}"
RUST_ROOT="${RUST_ROOT:-${WORKSPACE}/rust}"
MIN_CPUS="${MIN_CPUS:-6}"
PODMAN_STORAGE="${PODMAN_STORAGE:-${WORKSPACE}/containers}"
KATA_GPERF_URL="${KATA_GPERF_URL:-https://ftp.gnu.org/gnu/gperf/}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=15)
[ -f "${SSH_KEY}" ] && SSH_OPTS+=(-i "${SSH_KEY}")

# --- Functions ---

write_remote_script() {
    cat > "$1" <<'REMOTE_SCRIPT'
#!/bin/bash
# Installs Kata Containers on this host. Safe to re-run.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
KATA_REPO="${KATA_REPO:-https://github.com/kata-containers/kata-containers.git}"
KATA_REF="${KATA_REF:-}"
KATA_DISTRO="${KATA_DISTRO:-ubuntu}"
KATA_OS_VERSION="${KATA_OS_VERSION:-}"
KATA_ENGINE_RUNTIME="${KATA_ENGINE_RUNTIME:-crun}"
RUST_ROOT="${RUST_ROOT:-${WORKSPACE}/rust}"
MIN_CPUS="${MIN_CPUS:-6}"
PODMAN_STORAGE="${PODMAN_STORAGE:-${WORKSPACE}/containers}"
KATA_GPERF_URL="${KATA_GPERF_URL:-https://ftp.gnu.org/gnu/gperf/}"
KATA_SRC="${WORKSPACE}/kata-containers"
RUN_USER="$(id -un)"

log() { echo; echo "=== $* ==="; }

ARCH="$(uname -m)"
if [ "${ARCH}" != "x86_64" ]; then
    echo "ERROR: this script targets x86_64 (host is ${ARCH})."
    exit 1
fi

# --- 0. Verify 01_setup_k8s_crio.sh has completed ---

log "Checking the CRI-O build box is in place"
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

check_prereq "crio binary at /usr/local/bin/crio"        test -x /usr/local/bin/crio
check_prereq "crun binary at /usr/local/bin/crun"        test -x /usr/local/bin/crun
check_prereq "crictl binary at /usr/local/bin/crictl"    test -x /usr/local/bin/crictl
check_prereq "crio.service is active"                    sudo systemctl is-active --quiet crio
check_prereq "CRI-O source at ${WORKSPACE}/cri-o"        test -d "${WORKSPACE}/cri-o/.git"
check_prereq "Kubernetes source at ${WORKSPACE}/kubernetes" test -d "${WORKSPACE}/kubernetes/.git"
check_prereq "container-selinux is installed"            rpm -q container-selinux

HOST_CPUS="$(nproc)"
if [ "${HOST_CPUS}" -ge "${MIN_CPUS}" ]; then
    echo "  ok:      ${HOST_CPUS} CPUs (minimum ${MIN_CPUS})"
else
    echo "  MISSING: ${HOST_CPUS} CPUs, need at least ${MIN_CPUS}"
    echo "           Resize with: az vm resize -g <group> -n <vm> --size Standard_D8s_v5"
    PREREQ_FAILED=1
fi

if [ "${PREREQ_FAILED}" -ne 0 ]; then
    echo
    echo "ERROR: this host is not a completed CRI-O build box."
    echo "Run 01_setup_k8s_crio.sh against it first."
    exit 1
fi
echo "Prerequisites satisfied."

KUBECONFIG_PATH=/var/run/kubernetes/admin.kubeconfig
if sudo test -f "${KUBECONFIG_PATH}"; then
    echo "  ok:      kubeconfig at ${KUBECONFIG_PATH}"
else
    echo "  WARNING: no kubeconfig at ${KUBECONFIG_PATH}; the local cluster may not be up."
fi

# --- 1. Ensure the vhost modules are loaded ---

log "Ensuring vhost is running"
if lsmod | grep vhost; then
    echo "vhost modules already loaded."
else
    echo "No vhost modules loaded; loading them now."
    sudo modprobe vhost_vsock
    sudo modprobe vhost_net

    if ! lsmod | grep vhost; then
        echo "ERROR: vhost modules still not loaded after modprobe."
        exit 1
    fi
fi

log "Installing the vhost modules-load drop-in"
cat <<'EOF' | sudo tee /etc/modules-load.d/kata-vhost.conf
# Loaded at boot for Kata Containers: vsock carries the agent transport, net the VM
# networking.
vhost_vsock
vhost_net
EOF

# --- 2. Build dependencies ---

log "Installing Kata build dependencies"
sudo dnf install -y \
  podman containernetworking-plugins \
  dwarves flex bison elfutils-libelf-devel openssl-devel bc \
  qemu-img parted device-mapper-multipath \
  curl patch xz tar util-linux

log "Pointing podman at ${PODMAN_STORAGE} for the build"
sudo mkdir -p "${PODMAN_STORAGE}/storage" "${PODMAN_STORAGE}/runroot"
cat <<EOF | sudo tee "${PODMAN_STORAGE}/storage.conf" > /dev/null
[storage]
driver = "overlay"
graphroot = "${PODMAN_STORAGE}/storage"
runroot = "${PODMAN_STORAGE}/runroot"
EOF
export CONTAINERS_STORAGE_CONF="${PODMAN_STORAGE}/storage.conf"

cat <<'EOF' | sudo tee "${PODMAN_STORAGE}/containers.conf" > /dev/null
[containers]
label = false
EOF
export CONTAINERS_CONF="${PODMAN_STORAGE}/containers.conf"

sudo -E podman info --format 'store: {{.Store.GraphRoot}}'

# --- 2b. Give podman's containers their network back if Docker took it away ---

if sudo iptables -S FORWARD 2>/dev/null | grep -q '^-P FORWARD DROP'; then
    log "FORWARD policy is DROP (docker); re-allowing podman's bridge"
    for BRIDGE in cni-podman0 podman0; do
        sudo iptables -C FORWARD -i "${BRIDGE}" -j ACCEPT 2>/dev/null \
            || sudo iptables -I FORWARD 1 -i "${BRIDGE}" -j ACCEPT
        sudo iptables -C FORWARD -o "${BRIDGE}" \
            -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
            || sudo iptables -I FORWARD 1 -o "${BRIDGE}" \
                -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    done
    sudo iptables -S FORWARD | head -5
fi

# --- 3. Fetch the Kata source ---

log "Fetching Kata source"
if [ -d "${KATA_SRC}/.git" ]; then
    echo "Repository already present; fetching updates."
    sudo chown -R "${RUN_USER}:${RUN_USER}" "${KATA_SRC}"
    git -C "${KATA_SRC}" fetch --all --tags --prune
else
    git clone "${KATA_REPO}" "${KATA_SRC}"
    sudo chown -R "${RUN_USER}:${RUN_USER}" "${KATA_SRC}"
fi
if [ -n "${KATA_REF}" ]; then
    echo "Checking out ${KATA_REF}"
    git -C "${KATA_SRC}" checkout "${KATA_REF}"
fi
git -C "${KATA_SRC}" --no-pager log -1 --oneline

# --- 4. Install the Rust toolchain ---

log "Installing Rust into ${RUST_ROOT}"
sudo mkdir -p "${RUST_ROOT}/tmp" "${RUST_ROOT}/cargo" "${RUST_ROOT}/rustup" \
              "${RUST_ROOT}/gocache" "${RUST_ROOT}/gopath"
sudo chown -R "${RUN_USER}:${RUN_USER}" "${RUST_ROOT}"

export TMPDIR="${RUST_ROOT}/tmp"
export CARGO_HOME="${RUST_ROOT}/cargo"
export RUSTUP_HOME="${RUST_ROOT}/rustup"
export GOCACHE="${RUST_ROOT}/gocache"
export GOPATH="${RUST_ROOT}/gopath"

if [ -x "${CARGO_HOME}/bin/rustc" ]; then
    echo "Rust already installed; skipping rustup."
else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path
fi

# shellcheck disable=SC1091
source "${CARGO_HOME}/env"
rustc --version
cargo --version

if ! grep -q "Custom Rust workspace environment" "${HOME}/.bashrc" 2>/dev/null; then
    echo "Adding the Rust environment to ~/.bashrc"
    cat >> "${HOME}/.bashrc" <<EOF

# Custom Rust workspace environment
export TMPDIR=${RUST_ROOT}/tmp
export CARGO_HOME=${RUST_ROOT}/cargo
export RUSTUP_HOME=${RUST_ROOT}/rustup
export GOCACHE=${RUST_ROOT}/gocache
export GOPATH=${RUST_ROOT}/gopath
source ${RUST_ROOT}/cargo/env 2>/dev/null || true
EOF
else
    echo "~/.bashrc already carries the Rust environment."
fi

export PATH="${GOPATH}/bin:${PATH}"
go version

# --- 5. Build the runtime ---

log "Building the Kata runtime (go)"
# Reclaim ownership of any root-built config artifacts from previous install runs
sudo chown -R "${RUN_USER}:${RUN_USER}" "${KATA_SRC}"
pushd "${KATA_SRC}/src/runtime" > /dev/null
make
popd > /dev/null

# --- 6. Build the guest rootfs ---

log "Building the Kata guest rootfs (${KATA_DISTRO})"
"${KATA_SRC}/ci/install_yq.sh"

if [ -z "${KATA_OS_VERSION}" ]; then
    KATA_OS_VERSION="$(yq ".assets.image.architecture.$(uname -m).version" \
        "${KATA_SRC}/versions.yaml")"
fi
if [ -z "${KATA_OS_VERSION}" ] || [ "${KATA_OS_VERSION}" = "null" ]; then
    echo "ERROR: could not read the guest OS version from ${KATA_SRC}/versions.yaml."
    echo "Set KATA_OS_VERSION explicitly (an Ubuntu code name, e.g. 'resolute')."
    exit 1
fi
echo "Guest OS version: ${KATA_OS_VERSION}"

if [ -n "${KATA_GPERF_URL}" ]; then
    CURRENT_GPERF_URL="$(yq '.externals.gperf.url' "${KATA_SRC}/versions.yaml")"
    if [ "${CURRENT_GPERF_URL}" != "${KATA_GPERF_URL}" ]; then
        echo "Repointing gperf: ${CURRENT_GPERF_URL} -> ${KATA_GPERF_URL}"
        yq -i ".externals.gperf.url = \"${KATA_GPERF_URL}\"" "${KATA_SRC}/versions.yaml"
    else
        echo "gperf already points at ${KATA_GPERF_URL}"
    fi
fi

export distro="${KATA_DISTRO}"
export OS_VERSION="${KATA_OS_VERSION}"
export DOCKER_RUNTIME="${KATA_ENGINE_RUNTIME}"
export ROOTFS_DIR="$(realpath "${KATA_SRC}/tools/osbuilder/rootfs-builder")/rootfs"
sudo rm -rf "${ROOTFS_DIR}"
pushd "${KATA_SRC}/tools/osbuilder/rootfs-builder" > /dev/null
script -fec 'sudo -E env TMPDIR="${TMPDIR}" USE_PODMAN=true ./rootfs.sh "${distro}"' /dev/null
popd > /dev/null

sudo chown -R "${RUN_USER}:${RUN_USER}" "${KATA_SRC}"

# --- 7. Build the guest image ---

log "Building the Kata guest image"
pushd "${KATA_SRC}/tools/osbuilder/image-builder" > /dev/null
script -fec 'sudo -E env TMPDIR="${TMPDIR}" USE_PODMAN=true ./image_builder.sh "${ROOTFS_DIR}"' /dev/null
ls -l kata-containers.img
popd > /dev/null

# --- 8. Build the guest kernel ---

log "Building the Kata guest kernel"
pushd "${KATA_SRC}/tools/packaging/kernel" > /dev/null
./build-kernel.sh setup
./build-kernel.sh build
popd > /dev/null

# --- 9. Report the build artifacts ---

log "Build artifacts"
echo "Source tree:   ${KATA_SRC}"
echo "Commit:        $(git -C "${KATA_SRC}" log --format=%h -1 HEAD)"
echo "runtime:       $(ls -1 "${KATA_SRC}/src/runtime/containerd-shim-kata-v2" 2>/dev/null || echo 'NOT BUILT')"
echo "rootfs:        ${ROOTFS_DIR}"
echo "guest image:   ${KATA_SRC}/tools/osbuilder/image-builder/kata-containers.img"
echo "guest kernel:  $(find "${KATA_SRC}/tools/packaging/kernel" -maxdepth 5 -path '*/arch/x86/boot/bzImage' 2>/dev/null | head -1 || echo 'NOT BUILT')"
echo "guest vmlinux: $(find "${KATA_SRC}/tools/packaging/kernel" -maxdepth 2 -name vmlinux 2>/dev/null | head -1 || echo 'NOT BUILT')"
echo "NOT installed yet (deliberately): runtime binaries, /etc/kata-containers/configuration.toml,"
echo "/usr/share/kata-containers/kata-containers.img and the guest kernel."
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

REMOTE_SCRIPT_FILE=$(mktemp -t configure-kata.XXXXXX)
trap 'rm -f "${REMOTE_SCRIPT_FILE}"' EXIT
write_remote_script "${REMOTE_SCRIPT_FILE}"

echo "Copying provisioning script to the host..."
if ! scp "${SSH_OPTS[@]}" -q "${REMOTE_SCRIPT_FILE}" \
    "${ADMIN_USER}@${EXTERNAL_IP}:/tmp/configure-kata.sh"; then
    echo "ERROR: failed to copy the provisioning script to the host." >&2
    exit 1
fi

echo "Running Kata build on ${INSTANCE_NAME} (this takes a while)..."
echo "------------------------------------------------------"
if ! ssh "${SSH_OPTS[@]}" -t "${ADMIN_USER}@${EXTERNAL_IP}" \
    "WORKSPACE='${WORKSPACE}' KATA_REPO='${KATA_REPO}' KATA_REF='${KATA_REF}' KATA_DISTRO='${KATA_DISTRO}' KATA_OS_VERSION='${KATA_OS_VERSION}' KATA_ENGINE_RUNTIME='${KATA_ENGINE_RUNTIME}' RUST_ROOT='${RUST_ROOT}' MIN_CPUS='${MIN_CPUS}' PODMAN_STORAGE='${PODMAN_STORAGE}' KATA_GPERF_URL='${KATA_GPERF_URL}' bash /tmp/configure-kata.sh"; then
    echo "------------------------------------------------------"
    echo "ERROR: Kata setup failed on '${INSTANCE_NAME}'." >&2
    exit 1
fi

echo "------------------------------------------------------"
echo "Kata build complete on '${INSTANCE_NAME}'."
echo "Kata source:   ${WORKSPACE}/kata-containers"
echo "Rust toolchain: ${RUST_ROOT}"
echo "Nothing has been installed into a system directory yet."
echo "SSH: ssh ${ADMIN_USER}@${EXTERNAL_IP}"
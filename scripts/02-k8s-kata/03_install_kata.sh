#!/bin/bash

# Installs the Kata Containers integration into the system directories of the RHEL 9
# host built by 02_build_kata.sh[cite: 6, 7].
#
# That script deliberately stops after building: everything it produces stays under
# /workspace. This one is the counterpart that touches /etc and /opt.
#
# usage: 03_install_kata.sh [-c <config-file>] [<config-file>]

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

# Where the Kata artifacts are expected to end up
KATA_PREFIX="${KATA_PREFIX:-/opt/kata}"
KERNEL_PREFIXES="${KERNEL_PREFIXES:-/usr ${KATA_PREFIX}}"
RUST_ROOT="${RUST_ROOT:-${WORKSPACE}/rust}"

# Execution controls
RESTART_CRIO="${RESTART_CRIO:-1}"
RUN_TEST_POD="${RUN_TEST_POD:-1}"
TEST_POD_NAME="${TEST_POD_NAME:-kata-smoke-test}"
TEST_IMAGE="${TEST_IMAGE:-nginx}"
TEST_POD_TIMEOUT="${TEST_POD_TIMEOUT:-180}"
KEEP_TEST_POD="${KEEP_TEST_POD:-0}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=15)
[ -f "${SSH_KEY}" ] && SSH_OPTS+=(-i "${SSH_KEY}")

# --- Functions ---

write_remote_script() {
    cat > "$1" <<'REMOTE_SCRIPT'
#!/bin/bash
# Installs the Kata integration into this host's system directories. Safe to re-run.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
KATA_PREFIX="${KATA_PREFIX:-/opt/kata}"
KERNEL_PREFIXES="${KERNEL_PREFIXES:-/usr ${KATA_PREFIX}}"
RUST_ROOT="${RUST_ROOT:-${WORKSPACE}/rust}"
RESTART_CRIO="${RESTART_CRIO:-1}"
RUN_TEST_POD="${RUN_TEST_POD:-1}"
TEST_POD_NAME="${TEST_POD_NAME:-kata-smoke-test}"
TEST_IMAGE="${TEST_IMAGE:-nginx}"
TEST_POD_TIMEOUT="${TEST_POD_TIMEOUT:-180}"
KEEP_TEST_POD="${KEEP_TEST_POD:-0}"
CRIO_DROPIN_DIR=/etc/crio/crio.conf.d
KATA_SRC="${WORKSPACE}/kata-containers"
KERNEL_DIR="${KATA_SRC}/tools/packaging/kernel"
RUNTIME_DIR="${KATA_SRC}/src/runtime"

log() { echo; echo "=== $* ==="; }

# --- 0. Verify the host is the CRI-O build box ---

log "Checking CRI-O is in place"
if [ ! -x /usr/local/bin/crio ]; then
    echo "ERROR: no crio binary at /usr/local/bin/crio."
    echo "Run 01_setup_k8s_crio.sh against this host first."
    exit 1
fi
echo "  ok:      crio at /usr/local/bin/crio"
sudo mkdir -p "${CRIO_DROPIN_DIR}"

# --- 1. Install the guest kernel ---

log "Installing the Kata guest kernel"
if [ ! -d "${KERNEL_DIR}" ]; then
    echo "ERROR: no kernel directory at ${KERNEL_DIR}."
    echo "Run 02_build_kata.sh against this host first."
    exit 1
fi

if ! find "${KERNEL_DIR}" -maxdepth 5 -path '*/arch/x86/boot/bzImage' | grep -q .; then
    echo "ERROR: no bzImage under ${KERNEL_DIR}; the kernel has not been built."
    echo "Run 02_build_kata.sh against this host first."
    exit 1
fi

export GOPATH="${RUST_ROOT}/gopath"
export PATH="${GOPATH}/bin:${PATH}"
if ! command -v yq > /dev/null 2>&1; then
    echo "ERROR: yq is not on PATH (looked in ${GOPATH}/bin)."
    echo "It is installed by 02_build_kata.sh."
    exit 1
fi
echo "yq: $(command -v yq)"

for prefix in ${KERNEL_PREFIXES}; do
    echo
    echo "--- installing with PREFIX=${prefix} ---"
    pushd "${KERNEL_DIR}" > /dev/null
    sudo -E GOPATH="${GOPATH}" PATH="${PATH}" DESTDIR=/ PREFIX="${prefix}" \
        ./build-kernel.sh install
    popd > /dev/null
done

echo
for prefix in ${KERNEL_PREFIXES}; do
    echo "Installed into ${prefix}/share/kata-containers:"
    ls -l "${prefix}/share/kata-containers"
    echo
done

# --- 2. Install the containerd shim ---

log "Installing containerd-shim-kata-v2 into ${KATA_PREFIX}/bin"
if [ ! -d "${RUNTIME_DIR}" ]; then
    echo "ERROR: no runtime directory at ${RUNTIME_DIR}."
    echo "Run 02_build_kata.sh against this host first."
    exit 1
fi

pushd "${RUNTIME_DIR}" > /dev/null
export GOCACHE="${RUST_ROOT}/gocache"
make PREFIX="${KATA_PREFIX}" containerd-shim-v2

sudo -E GOPATH="${GOPATH}" GOCACHE="${GOCACHE}" PATH="${PATH}" \
    make DESTDIR=/ PREFIX="${KATA_PREFIX}" install-containerd-shim-v2
popd > /dev/null

ls -lZ "${KATA_PREFIX}/bin/containerd-shim-kata-v2"

# --- 3. Install the hypervisor configuration files ---

log "Installing the Kata configuration files into ${KATA_PREFIX}/share/defaults"
pushd "${RUNTIME_DIR}" > /dev/null

sudo rm -f config/configuration-*.toml
sudo -E GOPATH="${GOPATH}" GOCACHE="${GOCACHE}" PATH="${PATH}" \
    make DESTDIR=/ PREFIX="${KATA_PREFIX}" install-configs
popd > /dev/null

ls -l "${KATA_PREFIX}/share/defaults/kata-containers"

echo
echo "--- paths configuration-qemu.toml resolves to ---"
grep -E '^\s*(path|kernel|image|initrd|shared_fs|virtio_fs_daemon)\s*=' \
    "${KATA_PREFIX}/share/defaults/kata-containers/configuration-qemu.toml" || true

# --- 4. Install the hypervisor, virtiofsd and the guest image ---

log "Installing QEMU and virtiofsd"
sudo dnf install -y qemu-kvm virtiofsd

QEMU_BIN=""
for candidate in /usr/libexec/qemu-kvm /usr/bin/qemu-system-x86_64; do
    if [ -x "${candidate}" ]; then QEMU_BIN="${candidate}"; break; fi
done
if [ -z "${QEMU_BIN}" ]; then
    echo "ERROR: no QEMU binary found after installing qemu-kvm."
    exit 1
fi

VIRTIOFSD_BIN=""
for candidate in /usr/libexec/virtiofsd /usr/bin/virtiofsd; do
    if [ -x "${candidate}" ]; then VIRTIOFSD_BIN="${candidate}"; break; fi
done
if [ -z "${VIRTIOFSD_BIN}" ]; then
    echo "ERROR: no virtiofsd binary found after installing virtiofsd."
    exit 1
fi

sudo mkdir -p "${KATA_PREFIX}/bin" "${KATA_PREFIX}/libexec"
sudo ln -sf "${QEMU_BIN}" "${KATA_PREFIX}/bin/qemu-system-x86_64"
sudo ln -sf "${VIRTIOFSD_BIN}" "${KATA_PREFIX}/libexec/virtiofsd"
ls -l "${KATA_PREFIX}/bin/qemu-system-x86_64" "${KATA_PREFIX}/libexec/virtiofsd"
"${QEMU_BIN}" --version | head -1
"${VIRTIOFSD_BIN}" --version | head -1

log "Installing the guest image"
GUEST_IMAGE="${KATA_SRC}/tools/osbuilder/image-builder/kata-containers.img"
if [ ! -f "${GUEST_IMAGE}" ]; then
    echo "ERROR: no guest image at ${GUEST_IMAGE}."
    echo "Run 02_build_kata.sh against this host first."
    exit 1
fi
sudo install -D -m 0644 "${GUEST_IMAGE}" \
    "${KATA_PREFIX}/share/kata-containers/kata-containers.img"
ls -l "${KATA_PREFIX}/share/kata-containers/kata-containers.img"

if [ -c /dev/kvm ]; then
    echo "  ok:      /dev/kvm is present"
else
    echo "  WARNING: no /dev/kvm - this VM size does not expose nested virtualisation."
    echo "           Kata pods will fail to start. Resize to a v5-series size."
fi

# --- 5. Write the CRI-O defaults drop-in ---

log "Writing ${CRIO_DROPIN_DIR}/00-defaults"
cat <<'EOF' | sudo tee "${CRIO_DROPIN_DIR}/00-defaults" > /dev/null
[crio]
storage_option = [
  "overlay.skip_mount_home=true",
]

# Set debug logs in crio
[crio.runtime]
log_level = "debug"
EOF
sudo cat "${CRIO_DROPIN_DIR}/00-defaults"

# --- 6. Write the Kata runtime drop-in ---

log "Writing ${CRIO_DROPIN_DIR}/50-kata"
cat <<EOF | sudo tee "${CRIO_DROPIN_DIR}/50-kata" > /dev/null
[crio.runtime.runtimes.kata]
  runtime_path = "${KATA_PREFIX}/bin/containerd-shim-kata-v2"
  runtime_root = "/run/vc"
  runtime_type = "vm"
  privileged_without_host_devices = true
  runtime_config_path = "${KATA_PREFIX}/share/defaults/kata-containers/configuration-qemu.toml"
  runtime_pull_image = false
  allowed_annotations = [
    "io.containers.trace-syscall",
    "io.kubernetes.cri-o.Devices",
  ]
EOF
sudo cat "${CRIO_DROPIN_DIR}/50-kata"

# --- 7. Let container rootfs mounts reach the Kata shim ---

log "Writing the crio.service mount-propagation drop-in"
sudo mkdir -p /etc/systemd/system/crio.service.d
cat <<'EOF' | sudo tee /etc/systemd/system/crio.service.d/20-kata-mount-propagation.conf > /dev/null
[Service]
ExecStartPost=-/usr/bin/mount --make-rshared /var/lib/containers/storage/overlay
EOF
sudo cat /etc/systemd/system/crio.service.d/20-kata-mount-propagation.conf
sudo systemctl daemon-reload

# --- 8. Report which referenced paths are still missing ---

log "Checking the paths the drop-in points at"
KATA_INSTALLED=1
for path in \
    "${KATA_PREFIX}/bin/containerd-shim-kata-v2" \
    "${KATA_PREFIX}/share/defaults/kata-containers/configuration-qemu.toml"; do
    if [ -e "${path}" ]; then
        echo "  ok:      ${path}"
    else
        echo "  MISSING: ${path}"
        KATA_INSTALLED=0
    fi
done

log "Checking the paths configuration-qemu.toml points at"
QEMU_CONFIG="${KATA_PREFIX}/share/defaults/kata-containers/configuration-qemu.toml"
if [ -f "${QEMU_CONFIG}" ]; then
    for key in path kernel image virtio_fs_daemon; do
        value="$(grep -m1 -E "^\s*${key}\s*=" "${QEMU_CONFIG}" | sed -E 's/.*=\s*"(.*)"/\1/')"
        if [ -z "${value}" ]; then
            echo "  (no ${key} set)"
        elif [ -e "${value}" ]; then
            echo "  ok:      ${key} -> ${value}"
        else
            echo "  MISSING: ${key} -> ${value}"
            KATA_INSTALLED=0
        fi
    done
fi

# --- 9. Validate the TOML without restarting anything ---

log "Validating the rendered CRI-O configuration"
if ! CRIO_RENDERED="$(sudo /usr/local/bin/crio config 2>/dev/null)"; then
    echo "ERROR: crio could not parse its configuration after these drop-ins."
    sudo /usr/local/bin/crio config 2>&1 | tail -20
    exit 1
fi
echo "Configuration parses."
echo
echo "--- effective settings ---"
echo "${CRIO_RENDERED}" | grep -E '^#?[[:space:]]*log_level[[:space:]]*=' || true
echo "${CRIO_RENDERED}" | grep -E '^#?[[:space:]]*storage_option[[:space:]]*=' -A 3 || true
echo "${CRIO_RENDERED}" | grep -A 8 'crio.runtime.runtimes.kata' || \
    echo "(no kata handler in the rendered config - expected while ${KATA_PREFIX} is missing)"

# --- 10. Restart CRI-O, only when asked ---

if [ "${RESTART_CRIO}" = "1" ]; then
    log "Restarting crio.service"
    RESTART_MARK="$(date '+%Y-%m-%d %H:%M:%S')"
    sudo systemctl reset-failed crio 2>/dev/null || true
    sudo systemctl restart crio

    if ! sudo systemctl is-active --quiet crio; then
        echo "ERROR: crio.service failed to start with the new configuration."
        echo "The drop-ins are still on disk; move 50-kata aside and restart to recover."
        sudo journalctl -u crio --no-pager --since "${RESTART_MARK}" | tail -50
        exit 1
    fi
    echo "crio.service is active."

    log "What CRI-O made of the kata handler"
    if sudo journalctl -u crio --no-pager --since "${RESTART_MARK}" \
        | grep -iE 'kata|runtime handler' | head -20; then
        :
    else
        echo "(no kata or runtime-handler lines since the restart)"
    fi

    log "Runtime handlers CRI-O is advertising"
    sudo /usr/local/bin/crictl info 2>/dev/null \
        | grep -A 30 'runtimeHandlers' || echo "(crictl info returned nothing)"
else
    log "Not restarting crio.service"
    echo "The drop-ins are on disk but the running daemon has not read them."
    echo "Re-run with RESTART_CRIO=1, or restart by hand:  sudo systemctl restart crio"
fi

# --- 11. Register the RuntimeClass with Kubernetes ---

log "Applying the kata RuntimeClass"
KUBECONFIG_PATH=/var/run/kubernetes/admin.kubeconfig
KUBECTL="${WORKSPACE}/kubernetes/_output/bin/kubectl"

if ! sudo test -f "${KUBECONFIG_PATH}"; then
    echo "WARNING: no kubeconfig at ${KUBECONFIG_PATH}; skipping."
    echo "         Start the cluster with 01_setup_k8s_crio.sh, then re-run."
elif [ ! -x "${KUBECTL}" ]; then
    echo "WARNING: no kubectl at ${KUBECTL}; skipping."
else
    cat > "${WORKSPACE}/runtime.yaml" <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
EOF
    cat "${WORKSPACE}/runtime.yaml"
    echo
    sudo "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" apply -f "${WORKSPACE}/runtime.yaml"
    echo
    sudo "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" get runtimeclass
fi

# --- 12. Drop IPv6 from the cluster CNI configuration ---

log "Making the cluster CNI configuration IPv4-only"
CNI_CONF=/etc/cni/net.d/10-containerd-net.conflist
if [ ! -f "${CNI_CONF}" ]; then
    echo "WARNING: no ${CNI_CONF}; skipping."
    echo "         It is written by local-up-cluster.sh, so the cluster may not be up."
elif ! grep -q "2001:db8" "${CNI_CONF}"; then
    echo "${CNI_CONF} is already IPv4-only."
else
    if [ ! -f "${CNI_CONF}.orig" ]; then
        sudo cp "${CNI_CONF}" "${CNI_CONF}.orig"
        echo "Saved the dual-stack original to ${CNI_CONF}.orig"
    fi
    cat <<'EOF' | sudo tee "${CNI_CONF}" > /dev/null
{
 "cniVersion": "1.0.0",
 "name": "containerd-net",
 "plugins": [
   {
     "type": "ptp",
     "ipMasq": true,
     "ipam": {
       "type": "host-local",
       "ranges": [
         [{
           "subnet": "10.88.0.0/16"
         }]
       ],
       "routes": [
         { "dst": "0.0.0.0/0" }
       ]
     }
   },
   {
     "type": "portmap",
     "capabilities": {"portMappings": true},
     "externalSetMarkChain": "KUBE-MARK-MASQ"
   }
 ]
}
EOF
    sudo cat "${CNI_CONF}"
    echo
    echo "Pods created before this keep their old addressing; recreate them to pick it up."
fi

# --- 13. Run a sample Kata pod ---

TEST_POD_RESULT="skipped"

if [ "${RUN_TEST_POD}" != "1" ]; then
    log "RUN_TEST_POD=${RUN_TEST_POD}; not running the sample pod"
elif [ "${KATA_INSTALLED}" -ne 1 ]; then
    log "Something configuration-qemu.toml names is missing; not running the sample pod"
    echo "Scroll up to the MISSING lines in section 8: they name the exact paths."
    echo "Paths under /usr where ${KATA_PREFIX} was expected mean the config was"
    echo "generated with the default PREFIX; section 3 removes the stale copy to"
    echo "force it to be regenerated, so re-running this script clears it."
elif [ "${RESTART_CRIO}" != "1" ]; then
    log "crio.service was not restarted; not running the sample pod"
    echo "The kata handler is not live until it is. Re-run with RESTART_CRIO=1."
elif ! sudo test -f "${KUBECONFIG_PATH}" || [ ! -x "${KUBECTL}" ]; then
    log "No cluster to run the sample pod on; skipping"
    echo "Start it with 01_setup_k8s_crio.sh, then re-run."
else
    log "Running a sample Kata pod (${TEST_POD_NAME})"
    KUBE=(sudo "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}")

    cat > "${WORKSPACE}/${TEST_POD_NAME}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD_NAME}
spec:
  runtimeClassName: kata
  containers:
  - name: ${TEST_POD_NAME}
    image: ${TEST_IMAGE}
    imagePullPolicy: IfNotPresent
EOF
    cat "${WORKSPACE}/${TEST_POD_NAME}.yaml"
    echo

    "${KUBE[@]}" delete pod "${TEST_POD_NAME}" --ignore-not-found --wait --timeout=60s || true
    "${KUBE[@]}" apply -f "${WORKSPACE}/${TEST_POD_NAME}.yaml" || true

    echo
    echo "Waiting up to ${TEST_POD_TIMEOUT}s for it to become Ready..."
    if "${KUBE[@]}" wait --for=condition=Ready "pod/${TEST_POD_NAME}" \
        --timeout="${TEST_POD_TIMEOUT}s"; then
        TEST_POD_RESULT="passed"
    else
        TEST_POD_RESULT="failed"
    fi
    echo
    "${KUBE[@]}" get pod "${TEST_POD_NAME}" -o wide || true

    if [ "${TEST_POD_RESULT}" = "passed" ]; then
        log "Confirming the container really is in a VM"
        HOST_KERNEL="$(uname -r)"
        GUEST_KERNEL="$("${KUBE[@]}" exec "${TEST_POD_NAME}" -- uname -r 2>/dev/null || echo unknown)"
        echo "  host kernel:  ${HOST_KERNEL}"
        echo "  guest kernel: ${GUEST_KERNEL}"
        if [ "${GUEST_KERNEL}" = "unknown" ]; then
            echo "  WARNING: could not read the guest kernel (no shell in ${TEST_IMAGE}?)."
        elif [ "${GUEST_KERNEL}" = "${HOST_KERNEL}" ]; then
            echo "  WARNING: same kernel as the host, so this pod is NOT in a VM."
            TEST_POD_RESULT="failed"
        else
            echo "  Different kernels, so the pod is running inside its own VM."
        fi
        echo "  qemu processes: $(pgrep -c -f qemu-system 2>/dev/null || echo 0)"
    else
        log "The sample pod did not become Ready"
        "${KUBE[@]}" describe pod "${TEST_POD_NAME}" 2>/dev/null | tail -30 || true
        echo
        echo "--- kata shim, last 30 lines ---"
        sudo journalctl -t kata --no-pager -n 30 || true
        echo
        echo "--- crio, last lines mentioning kata ---"
        sudo journalctl -u crio --no-pager -n 500 2>/dev/null | grep -i kata | tail -20 || true
    fi

    if [ "${KEEP_TEST_POD}" = "1" ]; then
        echo
        echo "Leaving ${TEST_POD_NAME} in place (KEEP_TEST_POD=1)."
    else
        echo
        echo "Removing ${TEST_POD_NAME}."
        "${KUBE[@]}" delete pod "${TEST_POD_NAME}" --ignore-not-found --wait --timeout=60s || true
    fi
fi

# --- 14. Summary ---

log "Summary"
echo "Drop-ins written:"
sudo ls -1 "${CRIO_DROPIN_DIR}"
echo
echo "systemd drop-ins written:"
sudo ls -1 /etc/systemd/system/crio.service.d 2>/dev/null || echo "(none)"
echo
if [ "${KATA_INSTALLED}" -eq 1 ]; then
    echo "Kata artifacts are present under ${KATA_PREFIX}."
else
    echo "Kata is NOT yet installed under ${KATA_PREFIX}."
    echo "The build artifacts are still in ${WORKSPACE}/kata-containers; the kata handler"
    echo "stays disabled until they are installed into ${KATA_PREFIX}."
fi
echo
echo "Sample Kata pod: ${TEST_POD_RESULT}"

if [ "${TEST_POD_RESULT}" = "failed" ]; then
    echo
    echo "ERROR: the install completed but no Kata pod would run on this host."
    exit 1
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

REMOTE_SCRIPT_FILE=$(mktemp -t install-kata.XXXXXX)
trap 'rm -f "${REMOTE_SCRIPT_FILE}"' EXIT
write_remote_script "${REMOTE_SCRIPT_FILE}"

echo "Copying provisioning script to the host..."
if ! scp "${SSH_OPTS[@]}" -q "${REMOTE_SCRIPT_FILE}" \
    "${ADMIN_USER}@${EXTERNAL_IP}:/tmp/install-kata.sh"; then
    echo "ERROR: failed to copy the provisioning script to the host." >&2
    exit 1
fi

echo "Installing the Kata CRI-O configuration on ${INSTANCE_NAME}..."
echo "------------------------------------------------------"
if ! ssh "${SSH_OPTS[@]}" -t "${ADMIN_USER}@${EXTERNAL_IP}" \
    "WORKSPACE='${WORKSPACE}' KATA_PREFIX='${KATA_PREFIX}' KERNEL_PREFIXES='${KERNEL_PREFIXES}' RUST_ROOT='${RUST_ROOT}' RESTART_CRIO='${RESTART_CRIO}' RUN_TEST_POD='${RUN_TEST_POD}' TEST_POD_NAME='${TEST_POD_NAME}' TEST_IMAGE='${TEST_IMAGE}' TEST_POD_TIMEOUT='${TEST_POD_TIMEOUT}' KEEP_TEST_POD='${KEEP_TEST_POD}' bash /tmp/install-kata.sh"; then
    echo "------------------------------------------------------"
    echo "ERROR: Kata configuration failed on '${INSTANCE_NAME}'." >&2
    exit 1
fi

echo "------------------------------------------------------"
echo "CRI-O drop-ins installed on '${INSTANCE_NAME}'."
echo "SSH: ssh ${ADMIN_USER}@${EXTERNAL_IP}"
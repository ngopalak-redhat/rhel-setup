#!/bin/bash

# Wires up peer pods (the 'kata-remote' runtime) on the RHEL 9 host using the
# cloud-api-adaptor binaries that 01_build_coco.sh already produced,
# then runs a pod under it.
#
# usage: 02_setup_peerpods.sh [-c <config-file>] [<config-file>]

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
CAA_SRC="${CAA_SRC:-${WORKSPACE}/confidential-containers/cloud-api-adaptor/src/cloud-api-adaptor}"

PODVM_SIZE="${PODVM_SIZE:-Standard_DC2as_v5}"
CREATE_CONTAINER_TIMEOUT="${CREATE_CONTAINER_TIMEOUT:-300}"
SANDBOX_CGROUP_ONLY="${SANDBOX_CGROUP_ONLY:-true}"

COCO_COMMUNITY_GALLERY="${COCO_COMMUNITY_GALLERY:-cococommunity-42d8482d-92cd-415b-b332-7648bd978eff}"
PODVM_IMAGE_DEF_SRC="${PODVM_IMAGE_DEF_SRC:-peerpod-podvm-fedora}"
PODVM_IMAGE_VER_SRC="${PODVM_IMAGE_VER_SRC:-0.17.0}"
PODVM_SOURCE_REGION="${PODVM_SOURCE_REGION:-eastus}"

PODVM_GALLERY="${PODVM_GALLERY:-${RESOURCE_GROUP}_podvm_gallery}"
PODVM_IMAGE_DEF="${PODVM_IMAGE_DEF:-podvm-cvm-snp}"
PODVM_IMAGE_VERSION="${PODVM_IMAGE_VERSION:-${PODVM_IMAGE_VER_SRC}}"

PODVM_LOCAL_GALLERY="${PODVM_LOCAL_GALLERY:-${RESOURCE_GROUP}_podvm_local_gallery}"
PODVM_LOCAL_IMAGE_DEF="${PODVM_LOCAL_IMAGE_DEF:-podvm-local}"

PODVM_IMAGE_ID="${PODVM_IMAGE_ID:-}"

USE_TRUSTEE="${USE_TRUSTEE:-1}"
TEST_ATTESTATION="${TEST_ATTESTATION:-1}"
KBS_SMOKE_PATH="${KBS_SMOKE_PATH:-default/peerpod/smoke}"
TRUSTEE_OPERATOR_SRC="${TRUSTEE_OPERATOR_SRC:-${WORKSPACE}/confidential-containers/trustee-operator}"
KBS_PORT="${KBS_PORT:-8080}"
KBS_URL="${KBS_URL:-}"
AA_KBC_PARAMS="${AA_KBC_PARAMS:-}"

SP_FILE="${SP_FILE:-${OUTPUT_DIR}/${INSTANCE_NAME}-peerpods-sp.json}"
CREATE_SP="${CREATE_SP:-1}"

DISABLE_CVM="${DISABLE_CVM:-0}"
USE_PUBLIC_IP="${USE_PUBLIC_IP:-0}"
PODVM_NAT_GATEWAY="${PODVM_NAT_GATEWAY:-1}"

NAT_GATEWAY_NAME="${NAT_GATEWAY_NAME:-${INSTANCE_NAME}-podvm-nat}"
NAT_GATEWAY_IP_NAME="${NAT_GATEWAY_IP_NAME:-${INSTANCE_NAME}-podvm-nat-ip}"
CAA_EXTRA_ARGS="${CAA_EXTRA_ARGS:-}"

DELETE_AFTER=$(date -u -v+3d +"%Y-%m-%d" 2>/dev/null || date -u -d "+3 days" +"%Y-%m-%d")

VM_TAGS=(
    "owner=${OWNER}"
    "delete-after=${DELETE_AFTER}"
)
PEERPODS_TAGS="$(IFS=,; echo "${VM_TAGS[*]}")"

RESTART_CRIO="${RESTART_CRIO:-1}"
RUN_TEST_POD="${RUN_TEST_POD:-1}"
KEEP_TEST_POD="${KEEP_TEST_POD:-0}"
TEST_POD_NAME="${TEST_POD_NAME:-peerpod-smoke-test}"
TEST_IMAGE="${TEST_IMAGE:-nginx}"
TEST_POD_TIMEOUT="${TEST_POD_TIMEOUT:-600}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=15)
[ -f "${SSH_KEY}" ] && SSH_OPTS+=(-i "${SSH_KEY}")

# --- Functions ---

write_remote_script() {
    cat > "$1" <<'REMOTE_SCRIPT'
#!/bin/bash
# Configures peer pods / kata-remote on this host. Safe to re-run.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
CAA_SRC="${CAA_SRC:?}"
KATA_PREFIX="${KATA_PREFIX:-/opt/kata}"
CREATE_CONTAINER_TIMEOUT="${CREATE_CONTAINER_TIMEOUT:-300}"
SANDBOX_CGROUP_ONLY="${SANDBOX_CGROUP_ONLY:-true}"
PEERPODS_CONF_DIR=/etc/peer-pods
CRIO_DROPIN=/etc/crio/crio.conf.d/60-kata-remote
CAA_UNIT=/etc/systemd/system/cloud-api-adaptor.service
CAA_SOCKET=/run/peerpod/hypervisor.sock
USE_TRUSTEE="${USE_TRUSTEE:-0}"
TEST_ATTESTATION="${TEST_ATTESTATION:-0}"

KBS_SMOKE_PATH="${KBS_SMOKE_PATH:-default/peerpod/smoke}"
KBS_SMOKE_GUEST_PATH=/run/confidential-containers/cdh/kbs/peerpod/smoke
TRUSTEE_OPERATOR_SRC="${TRUSTEE_OPERATOR_SRC:-}"
KBS_URL="${KBS_URL:-}"
KBS_PORT="${KBS_PORT:-8080}"
AA_KBC_PARAMS="${AA_KBC_PARAMS:-}"

PRIVATE_IP="${PRIVATE_IP:-}"
SUBNET_CIDR="${SUBNET_CIDR:-}"

TRUSTEE_NS=trustee-operator-system
KBS_DEPLOYMENT=trustee-deployment
KBS_SERVICE=kbs-service
KBS_ROLLOUT_TIMEOUT="${KBS_ROLLOUT_TIMEOUT:-300}"

KBS_SECRET_NAME=""
KBS_SECRET_KEY=""
OPERATOR_IMAGE=""
OPERATOR_DEPLOY=""
KBS_NODEPORT=""
AUTH_DIR=/etc/trustee-operator
KUBECONFIG_PATH=/var/run/kubernetes/admin.kubeconfig
KUBECTL="${WORKSPACE}/kubernetes/_output/bin/kubectl"

log() { echo; echo "=== $* ==="; }

# --- 0. Prerequisites ---

log "Checking prerequisites"

FAILED=0
require_file() {
    if [ -e "$1" ]; then
        echo "  ok:      $1"
    else
        echo "  MISSING: $1"
        echo "           produced by $2"
        FAILED=1
    fi
}

require_file "${CAA_SRC}/cloud-api-adaptor" "01_build_coco.sh"
require_file "${CAA_SRC}/az-copy-image"     "01_build_coco.sh"
require_file "${KATA_PREFIX}/bin/containerd-shim-kata-v2" "03_install_kata.sh"
require_file "${KATA_PREFIX}/share/defaults/kata-containers/configuration-remote.toml" "03_install_kata.sh"
require_file /tmp/peer-pods-credentials.env "this script, over scp"

if [ "${USE_TRUSTEE}" = "1" ]; then
    require_file "${TRUSTEE_OPERATOR_SRC}/dist/install.yaml" "01_build_coco.sh"

    if ! sudo test -f "${KUBECONFIG_PATH}"; then
        echo "  MISSING: ${KUBECONFIG_PATH}"
        echo "           USE_TRUSTEE=1 runs the KBS in the cluster, so a cluster is"
        echo "           required. Start one with 01_setup_k8s_crio.sh, or"
        echo "           re-run with USE_TRUSTEE=0 for unattested pod VMs."
        FAILED=1
    else
        echo "  ok:      ${KUBECONFIG_PATH}"
    fi
    require_file "${KUBECTL}" "01_setup_k8s_crio.sh"

    OPERATOR_IMAGE="$(grep -A1 'name: OPERATOR_IMAGE_NAME' \
        "${TRUSTEE_OPERATOR_SRC}/dist/install.yaml" 2>/dev/null \
        | sed -n 's/^[[:space:]]*value:[[:space:]]*//p' | head -1 || true)"
    if [ -z "${OPERATOR_IMAGE}" ]; then
        echo "  MISSING: OPERATOR_IMAGE_NAME is not set in dist/install.yaml"
        echo "           The controller refuses to start without it - see"
        echo "           kbsconfig_controller.go, 'must be set'. Re-run"
        echo "           01_build_coco.sh, which patches it in."
        FAILED=1
    elif ! command -v crictl > /dev/null 2>&1; then
        echo "  ok:      ${OPERATOR_IMAGE} (no crictl here, so not verified)"
    elif [ -n "$(sudo crictl images -q "${OPERATOR_IMAGE}" 2>/dev/null || true)" ]; then
        echo "  ok:      ${OPERATOR_IMAGE} (visible to CRI-O)"
    else
        echo "  MISSING: ${OPERATOR_IMAGE} is not in CRI-O's image store"
        echo "           dist/install.yaml names it and nothing will pull it - it is a"
        echo "           local build. Re-run 01_build_coco.sh."
        FAILED=1
    fi

    IFS='/' read -r -a SMOKE_PARTS <<< "${KBS_SMOKE_PATH}"
    if [ "${#SMOKE_PARTS[@]}" -ne 3 ] || [ "${SMOKE_PARTS[0]}" != "default" ] \
        || [ -z "${SMOKE_PARTS[1]}" ] || [ -z "${SMOKE_PARTS[2]}" ]; then
        echo "  MISSING: KBS_SMOKE_PATH='${KBS_SMOKE_PATH}' must be default/<name>/<key>"
        FAILED=1
    else
        KBS_SECRET_NAME="${SMOKE_PARTS[1]}"
        KBS_SECRET_KEY="${SMOKE_PARTS[2]}"
        echo "  ok:      ${KBS_SMOKE_PATH} <- secret/${KBS_SECRET_NAME} key ${KBS_SECRET_KEY}"
    fi
fi

if ! systemctl is-active --quiet crio; then
    echo "  crio.service is not active."
    echo "  Run 01_setup_k8s_crio.sh against this host first."
    FAILED=1
else
    echo "  ok:      crio.service is active"
fi

[ "${FAILED}" -eq 1 ] && exit 1

CONFIGURED_SOCKET="$(sed -n 's/^remote_hypervisor_socket[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' \
    "${KATA_PREFIX}/share/defaults/kata-containers/configuration-remote.toml" || true)"
if [ -n "${CONFIGURED_SOCKET}" ] && [ "${CONFIGURED_SOCKET}" != "${CAA_SOCKET}" ]; then
    echo "  configuration-remote.toml dials ${CONFIGURED_SOCKET}; using that."
    CAA_SOCKET="${CONFIGURED_SOCKET}"
fi
echo "  socket:  ${CAA_SOCKET}"

REMOTE_TOML="${KATA_PREFIX}/share/defaults/kata-containers/configuration-remote.toml"
CONFIGURED_TIMEOUT="$(sed -n 's/^create_container_timeout[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' \
    "${REMOTE_TOML}" || true)"
if [ "${CONFIGURED_TIMEOUT}" = "${CREATE_CONTAINER_TIMEOUT}" ]; then
    echo "  timeout: create_container_timeout already ${CREATE_CONTAINER_TIMEOUT}s"
else
    sudo sed -i "s/^create_container_timeout[[:space:]]*=.*/create_container_timeout = ${CREATE_CONTAINER_TIMEOUT}/" \
        "${REMOTE_TOML}"
    echo "  timeout: create_container_timeout ${CONFIGURED_TIMEOUT:-unset} -> ${CREATE_CONTAINER_TIMEOUT}s"
fi

CONFIGURED_CGROUP_ONLY="$(sed -n 's/^sandbox_cgroup_only[[:space:]]*=[[:space:]]*\([a-z]*\).*/\1/p' \
    "${REMOTE_TOML}" || true)"
if [ "${CONFIGURED_CGROUP_ONLY}" = "${SANDBOX_CGROUP_ONLY}" ]; then
    echo "  cgroup:  sandbox_cgroup_only already ${SANDBOX_CGROUP_ONLY}"
else
    sudo sed -i "s/^sandbox_cgroup_only[[:space:]]*=.*/sandbox_cgroup_only = ${SANDBOX_CGROUP_ONLY}/" \
        "${REMOTE_TOML}"
    echo "  cgroup:  sandbox_cgroup_only ${CONFIGURED_CGROUP_ONLY:-unset} -> ${SANDBOX_CGROUP_ONLY}"
fi

POD_CIDR="$(sed -n 's/.*"subnet"[[:space:]]*:[[:space:]]*"\([0-9.]*\/[0-9]*\)".*/\1/p' \
    /etc/cni/net.d/*.conflist 2>/dev/null | head -1 || true)"
POD_CIDR="${POD_CIDR:-10.88.0.0/16}"
if ! systemctl is-active --quiet firewalld; then
    echo "  egress:  firewalld is not running; pods forward freely"
elif sudo firewall-cmd --quiet --permanent --zone=trusted \
        --query-source="${POD_CIDR}" 2>/dev/null; then
    echo "  egress:  ${POD_CIDR} is already in firewalld's trusted zone"
else
    sudo firewall-cmd --permanent --zone=trusted --add-source="${POD_CIDR}" > /dev/null
    sudo firewall-cmd --reload > /dev/null
    echo "  egress:  ${POD_CIDR} added to firewalld's trusted zone"
fi

# --- 1. Install the binaries ---

log "Installing the cloud-api-adaptor binaries"
for BIN in cloud-api-adaptor az-copy-image; do
    sudo install -m 0755 "${CAA_SRC}/${BIN}" "/usr/local/bin/${BIN}"
    echo "  /usr/local/bin/${BIN}"
done
sudo restorecon -F /usr/local/bin/cloud-api-adaptor /usr/local/bin/az-copy-image 2>/dev/null || true
/usr/local/bin/cloud-api-adaptor version 2>/dev/null || true

# --- 2. Trustee: the Key Broker Service ---

INITDATA=""
if [ "${USE_TRUSTEE}" != "1" ]; then
    log "USE_TRUSTEE=${USE_TRUSTEE}; no KBS, and the pod VMs will not be attested"
else
    log "Deploying the Key Broker Service with the trustee-operator"
    KUBE=(sudo "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}")

    if [ -f /etc/systemd/system/trustee-kbs.service ]; then
        echo "Removing trustee-kbs.service; the operator replaces it."
        sudo systemctl disable --now trustee-kbs.service > /dev/null 2>&1 || true
        sudo rm -f /etc/systemd/system/trustee-kbs.service
        sudo systemctl daemon-reload
        if systemctl is-active --quiet firewalld && [ -n "${SUBNET_CIDR}" ]; then
            OLD_HOST_RULE="rule family=ipv4 source address=${SUBNET_CIDR} port port=${KBS_PORT} protocol=tcp accept"
            sudo firewall-cmd --permanent --remove-rich-rule="${OLD_HOST_RULE}" \
                > /dev/null 2>&1 || true
            sudo firewall-cmd --reload > /dev/null 2>&1 || true
        fi
    fi

    log "Applying ${TRUSTEE_OPERATOR_SRC}/dist/install.yaml"
    "${KUBE[@]}" apply -f "${TRUSTEE_OPERATOR_SRC}/dist/install.yaml"

    "${KUBE[@]}" wait --for=condition=established --timeout=60s \
        crd/kbsconfigs.confidentialcontainers.org

    OPERATOR_DEPLOY="$("${KUBE[@]}" -n "${TRUSTEE_NS}" get deployment \
        -l control-plane=controller-manager \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${OPERATOR_DEPLOY}" ]; then
        echo "ERROR: no controller-manager Deployment in ${TRUSTEE_NS} after the apply."
        "${KUBE[@]}" -n "${TRUSTEE_NS}" get all || true
        exit 1
    fi
    if ! "${KUBE[@]}" -n "${TRUSTEE_NS}" rollout status "deployment/${OPERATOR_DEPLOY}" \
        --timeout=180s; then
        echo "ERROR: the trustee-operator controller did not become ready."
        "${KUBE[@]}" -n "${TRUSTEE_NS}" get pods -o wide || true
        exit 1
    fi

    AUTH_DIR=/etc/trustee-operator
    sudo mkdir -p "${AUTH_DIR}"
    if ! sudo test -f "${AUTH_DIR}/privateKey"; then
        echo "Generating the KBS admin key in ${AUTH_DIR}"
        sudo openssl genpkey -algorithm ed25519 -out "${AUTH_DIR}/privateKey"
        sudo chmod 0600 "${AUTH_DIR}/privateKey"
    fi
    sudo openssl pkey -in "${AUTH_DIR}/privateKey" -pubout -out "${AUTH_DIR}/kbs.pem"
    sudo chmod 0644 "${AUTH_DIR}/kbs.pem"

    "${KUBE[@]}" -n "${TRUSTEE_NS}" create secret generic kbs-auth-public-key \
        --from-file="kbs.pem=${AUTH_DIR}/kbs.pem" \
        --dry-run=client -o yaml | "${KUBE[@]}" apply -f -

    log "Writing the KBS configuration into ${TRUSTEE_NS}"
    "${KUBE[@]}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kbs-config
  namespace: ${TRUSTEE_NS}
data:
  kbs-config.toml: |
    [http_server]
    sockets = ["0.0.0.0:${KBS_PORT}"]
    insecure_http = true

    [attestation_token]
    insecure_header_jwk = true

    [attestation_service]
    type = "coco_as_builtin"

    [attestation_service.attestation_token_broker]
    duration_min = 5

    [attestation_service.rvps_config]
    type = "BuiltIn"

    [admin]
    authorization_mode = "DenyAll"

    [storage_backend]
    storage_type = "LocalFs"

    [storage_backend.backends.local_fs]
    dir_path = "/opt/confidential-containers/storage"

    [[plugins]]
    name = "resource"
    storage_backend_type = "kvstorage"
EOF

    "${KUBE[@]}" -n "${TRUSTEE_NS}" create secret generic "${KBS_SECRET_NAME}" \
        --from-literal="${KBS_SECRET_KEY}=peer-pods smoke test resource" \
        --dry-run=client -o yaml | "${KUBE[@]}" apply -f -
    echo "  kbs:///${KBS_SMOKE_PATH} <- secret/${KBS_SECRET_NAME} key ${KBS_SECRET_KEY}"

    log "Creating the KbsConfig"
    "${KUBE[@]}" apply -f - <<EOF
apiVersion: confidentialcontainers.org/v1alpha1
kind: KbsConfig
metadata:
  name: kbsconfig-peerpods
  namespace: ${TRUSTEE_NS}
spec:
  kbsConfigMapName: kbs-config
  kbsAuthSecretName: kbs-auth-public-key
  kbsDeploymentType: AllInOneDeployment
  kbsServiceType: NodePort
  kbsSecretResources:
    - ${KBS_SECRET_NAME}
EOF

    echo "Waiting for ${KBS_DEPLOYMENT} to appear..."
    for ATTEMPT in $(seq 1 30); do
        "${KUBE[@]}" -n "${TRUSTEE_NS}" get "deployment/${KBS_DEPLOYMENT}" \
            > /dev/null 2>&1 && break
        sleep 2
    done

    if ! "${KUBE[@]}" -n "${TRUSTEE_NS}" rollout status "deployment/${KBS_DEPLOYMENT}" \
        --timeout="${KBS_ROLLOUT_TIMEOUT}s"; then
        echo "ERROR: the KBS deployment did not become ready."
        "${KUBE[@]}" -n "${TRUSTEE_NS}" get pods -o wide || true
        exit 1
    fi

    KBS_NODEPORT="$("${KUBE[@]}" -n "${TRUSTEE_NS}" get "service/${KBS_SERVICE}" \
        -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
    if [ -z "${KBS_NODEPORT}" ]; then
        echo "ERROR: ${KBS_SERVICE} has no nodePort."
        exit 1
    fi
    echo "  ${KBS_SERVICE} is on nodePort ${KBS_NODEPORT}"

    if [ -z "${KBS_URL}" ]; then
        [ -n "${PRIVATE_IP}" ] \
            || { echo "ERROR: no private IP, so the guests have no address to attest to."; exit 1; }
        KBS_URL="http://${PRIVATE_IP}:${KBS_NODEPORT}"
    else
        echo "  KBS_URL was set explicitly; using ${KBS_URL} rather than the NodePort"
    fi

    if systemctl is-active --quiet firewalld && [ -n "${SUBNET_CIDR}" ]; then
        while read -r OLD_RULE; do
            OLD_PORT="$(sed -n 's/.*port port="\([0-9]*\)".*/\1/p' <<< "${OLD_RULE}")"
            [ -z "${OLD_PORT}" ] && continue
            [ "${OLD_PORT}" -ge 30000 ] && [ "${OLD_PORT}" -le 32767 ] || continue
            [ "${OLD_PORT}" = "${KBS_NODEPORT}" ] && continue
            sudo firewall-cmd --permanent --remove-rich-rule="${OLD_RULE}" > /dev/null 2>&1 || true
        done < <(sudo firewall-cmd --permanent --list-rich-rules 2>/dev/null \
            | grep -F "source address=\"${SUBNET_CIDR}\"" || true)

        RICH_RULE="rule family=ipv4 source address=${SUBNET_CIDR} port port=${KBS_NODEPORT} protocol=tcp accept"
        if sudo firewall-cmd --quiet --permanent --query-rich-rule="${RICH_RULE}" 2>/dev/null; then
            echo "  firewalld already allows ${SUBNET_CIDR} -> ${KBS_NODEPORT}/tcp"
        else
            sudo firewall-cmd --permanent --add-rich-rule="${RICH_RULE}" > /dev/null
            echo "  firewalld now allows ${SUBNET_CIDR} -> ${KBS_NODEPORT}/tcp"
        fi
        sudo firewall-cmd --reload > /dev/null
    fi

    echo "Checking ${KBS_URL} from this host..."
    KBS_CODE=000
    for ATTEMPT in $(seq 1 15); do
        KBS_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
            "${KBS_URL}/kbs/v0/resource/${KBS_SMOKE_PATH}" || true)"
        [ "${KBS_CODE}" != "000" ] && break
        sleep 2
    done
    if [ "${KBS_CODE}" = "000" ]; then
        echo "ERROR: nothing answered on ${KBS_URL}."
        exit 1
    fi
    echo "  HTTP ${KBS_CODE} - the KBS is reachable on the address the guests will use."

    CDH_CREDENTIALS=""
    if [ "${TEST_ATTESTATION}" = "1" ]; then
        CDH_CREDENTIALS="$(cat <<EOF

[[credentials]]
path = '${KBS_SMOKE_GUEST_PATH}'
resource_uri = 'kbs:///${KBS_SMOKE_PATH}'
EOF
)"
    fi

    log "Building the initdata that points the guests at ${KBS_URL}"
    INITDATA_TOML="$(cat <<EOF
algorithm = "sha384"
version = "0.1.0"

[data]
"aa.toml" = '''
[token_configs]
[token_configs.coco_as]
url = '${KBS_URL}'

[token_configs.kbs]
url = '${KBS_URL}'
'''

"cdh.toml" = '''
socket = 'unix:///run/confidential-containers/cdh.sock'

[kbc]
name = 'cc_kbc'
url = '${KBS_URL}'
${CDH_CREDENTIALS}
'''
EOF
)"
    INITDATA="$(printf '%s\n' "${INITDATA_TOML}" | gzip -n | base64 -w0)"
    echo "${INITDATA_TOML}"
    echo
    echo "  encoded: ${#INITDATA} bytes of base64"
fi

# --- 3. Configuration and credentials ---

log "Writing ${PEERPODS_CONF_DIR}"
sudo mkdir -p "${PEERPODS_CONF_DIR}"

sudo tee "${PEERPODS_CONF_DIR}/peer-pods.env" > /dev/null <<EOF
AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
AZURE_REGION=${AZURE_REGION}
AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
AZURE_SUBNET_ID=${AZURE_SUBNET_ID}
AZURE_NSG_ID=${AZURE_NSG_ID}
AZURE_INSTANCE_SIZE=${PODVM_SIZE}
AZURE_IMAGE_ID=${PODVM_IMAGE_ID}
DISABLECVM=${DISABLECVM}
USE_PUBLIC_IP=${USE_PUBLIC_IP_BOOL}
TAGS=${PEERPODS_TAGS}
EOF

if [ "${USE_TRUSTEE}" = "1" ] && [ -n "${KBS_URL}" ]; then
    AA_KBC_PARAMS_VAL="${AA_KBC_PARAMS:-cc_kbc::${KBS_URL}}"
    echo "AA_KBC_PARAMS=${AA_KBC_PARAMS_VAL}" | sudo tee -a "${PEERPODS_CONF_DIR}/peer-pods.env" > /dev/null
fi

if [ -n "${INITDATA}" ]; then
    echo "INITDATA=${INITDATA}" | sudo tee -a "${PEERPODS_CONF_DIR}/peer-pods.env" > /dev/null
fi
sudo chmod 0644 "${PEERPODS_CONF_DIR}/peer-pods.env"

set +e
set -a
# shellcheck disable=SC1091
. /tmp/peer-pods-credentials.env
set +a
set -e

sudo install -m 0600 -o root -g root /tmp/peer-pods-credentials.env \
    "${PEERPODS_CONF_DIR}/peer-pods-credentials.env"
rm -f /tmp/peer-pods-credentials.env
echo "  peer-pods.env               0644"
echo "  peer-pods-credentials.env   0600 (client secret; not printed)"
echo
sudo cat "${PEERPODS_CONF_DIR}/peer-pods.env" \
    | sed 's/^\(INITDATA=.\{16\}\).*/\1... (truncated)/'

# --- 4. Import the pod VM image ---

if [ -n "${PODVM_IMAGE_ID}" ]; then
    log "Pod VM image already present; skipping the import"
    echo "${PODVM_IMAGE_ID}"
else
    log "Importing the pod VM image into ${PODVM_GALLERY}"
    echo "Source:  ${COMMUNITY_IMAGE_ID}"
    echo "Target:  ${PODVM_GALLERY}/${PODVM_IMAGE_DEF}/${PODVM_IMAGE_VERSION}"
    echo "Regions: ${PODVM_TARGET_REGIONS}"
    echo "This takes about 15 minutes."
    echo

    AZURE_LOCATION="${PODVM_SOURCE_REGION}" \
    AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}" \
    AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}" \
        /usr/local/bin/az-copy-image \
            -community-image-id "${COMMUNITY_IMAGE_ID}" \
            -image-gallery "${PODVM_GALLERY}" \
            -image-definition "${PODVM_IMAGE_DEF}" \
            -image-version "${PODVM_IMAGE_VERSION}" \
            -target-regions "${PODVM_TARGET_REGIONS}"

    PODVM_IMAGE_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${AZURE_RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${PODVM_GALLERY}/images/${PODVM_IMAGE_DEF}/versions/${PODVM_IMAGE_VERSION}"
    echo
    echo "Imported: ${PODVM_IMAGE_ID}"

    sudo sed -i "s|^AZURE_IMAGE_ID=.*|AZURE_IMAGE_ID=${PODVM_IMAGE_ID}|" \
        "${PEERPODS_CONF_DIR}/peer-pods.env"
fi

# --- 5. Run the cloud-api-adaptor daemon ---

log "Installing ${CAA_UNIT}"
sudo tee "${CAA_UNIT}" > /dev/null <<EOF
[Unit]
Description=Cloud API Adaptor (peer pods / kata-remote)
Documentation=https://github.com/confidential-containers/cloud-api-adaptor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${PEERPODS_CONF_DIR}/peer-pods.env
EnvironmentFile=${PEERPODS_CONF_DIR}/peer-pods-credentials.env
ExecStart=/usr/local/bin/cloud-api-adaptor azure ${CAA_EXTRA_ARGS}
RuntimeDirectory=peerpod
RuntimeDirectoryMode=0755
Restart=on-failure
RestartSec=5
StartLimitBurst=5
StartLimitIntervalSec=120

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cloud-api-adaptor.service > /dev/null 2>&1 || true
sudo systemctl restart cloud-api-adaptor.service

echo "Waiting for ${CAA_SOCKET}..."
CAA_READY=0
for ATTEMPT in $(seq 1 30); do
    if sudo test -S "${CAA_SOCKET}"; then
        CAA_READY=1
        break
    fi
    if ! systemctl is-active --quiet cloud-api-adaptor.service; then
        break
    fi
    sleep 2
done

if [ "${CAA_READY}" -ne 1 ]; then
    echo "ERROR: the daemon did not create its socket."
    sudo systemctl status cloud-api-adaptor.service --no-pager -l | head -20 || true
    exit 1
fi
echo "Socket is up."
echo
sudo journalctl -u cloud-api-adaptor.service --no-pager -n 15

# --- 6. Give CRI-O a kata-remote handler ---

log "Writing ${CRIO_DROPIN}"
sudo tee "${CRIO_DROPIN}" > /dev/null <<EOF
[crio.runtime.runtimes.kata-remote]
  runtime_path = "${KATA_PREFIX}/bin/containerd-shim-kata-v2"
  runtime_root = "/run/vc"
  runtime_type = "vm"
  privileged_without_host_devices = true
  runtime_config_path = "${KATA_PREFIX}/share/defaults/kata-containers/configuration-remote.toml"
  runtime_pull_image = true
  allowed_annotations = [
    "io.containers.trace-syscall",
    "io.kubernetes.cri-o.Devices",
  ]
EOF
cat "${CRIO_DROPIN}"

log "Validating the rendered CRI-O configuration"
if ! sudo /usr/local/bin/crio config > /dev/null 2>&1; then
    echo "ERROR: crio could not parse its configuration after this drop-in."
    sudo /usr/local/bin/crio config 2>&1 | tail -20
    exit 1
fi
echo "Configuration parses."

# --- 7. Restart CRI-O ---

if [ "${RESTART_CRIO}" = "1" ]; then
    log "Restarting crio.service"
    sudo systemctl restart crio
    sleep 5
    systemctl is-active crio
    echo
    sudo crictl info 2>/dev/null | grep -A 30 'runtimeHandlers' \
        | grep -B2 -A2 'kata-remote' || echo "(kata-remote not listed by crictl info)"
else
    log "Not restarting crio.service"
fi

# --- 8. Register the RuntimeClass ---

log "Applying the kata-remote RuntimeClass"
if ! sudo test -f "${KUBECONFIG_PATH}"; then
    echo "WARNING: no kubeconfig at ${KUBECONFIG_PATH}; skipping."
elif [ ! -x "${KUBECTL}" ]; then
    echo "WARNING: no kubectl at ${KUBECTL}; skipping."
else
    cat > "${WORKSPACE}/runtime-kata-remote.yaml" <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata-remote
handler: kata-remote
EOF
    cat "${WORKSPACE}/runtime-kata-remote.yaml"
    echo
    sudo "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" apply -f "${WORKSPACE}/runtime-kata-remote.yaml"
    echo
    sudo "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" get runtimeclass
fi

# --- 9. Run a pod under kata-remote ---

TEST_POD_RESULT="skipped"
ATTESTED="not tested"

if [ "${RUN_TEST_POD}" != "1" ]; then
    log "RUN_TEST_POD=${RUN_TEST_POD}; not running the pod"
elif [ "${RESTART_CRIO}" != "1" ]; then
    log "crio.service was not restarted; not running the pod"
elif ! sudo test -f "${KUBECONFIG_PATH}" || [ ! -x "${KUBECTL}" ]; then
    log "No cluster to run the pod on; skipping"
else
    log "Running a peer pod (${TEST_POD_NAME})"
    KUBE=(sudo "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}")

    cat > "${WORKSPACE}/${TEST_POD_NAME}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD_NAME}
spec:
  runtimeClassName: kata-remote
  containers:
  - name: ${TEST_POD_NAME}
    image: ${TEST_IMAGE}
    imagePullPolicy: Always
EOF
    cat "${WORKSPACE}/${TEST_POD_NAME}.yaml"
    echo

    "${KUBE[@]}" delete pod "${TEST_POD_NAME}" --ignore-not-found --wait --timeout=120s || true

    KBS_MARK="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    "${KUBE[@]}" apply -f "${WORKSPACE}/${TEST_POD_NAME}.yaml" || true

    echo
    echo "Waiting up to ${TEST_POD_TIMEOUT}s for peer pod creation..."
    if "${KUBE[@]}" wait --for=condition=Ready "pod/${TEST_POD_NAME}" \
        --timeout="${TEST_POD_TIMEOUT}s"; then
        TEST_POD_RESULT="passed"
    else
        TEST_POD_RESULT="failed"
    fi
    echo
    "${KUBE[@]}" get pod "${TEST_POD_NAME}" -o wide || true

    if [ "${TEST_POD_RESULT}" = "passed" ]; then
        log "Confirming the container really is in a remote VM"
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
            echo "  Different kernels, so the pod is in its own VM."
        fi
        echo
        echo "  Pod VM, as the daemon reported it:"
        sudo journalctl -u cloud-api-adaptor.service --no-pager -n 200 \
            | grep -iE 'created an instance|instance id|podvm-' | tail -5 \
            || echo "  (nothing matched in the daemon log)"
    else
        log "The pod did not become Ready"
        "${KUBE[@]}" describe pod "${TEST_POD_NAME}" 2>/dev/null | tail -30 || true
    fi

    if [ "${USE_TRUSTEE}" = "1" ]; then
        log "Trustee KBS: requests from the guest"
        ATTESTED="no"
        KBS_REQUESTS="$("${KUBE[@]}" -n "${TRUSTEE_NS}" logs \
            "deployment/${KBS_DEPLOYMENT}" -c kbs --since-time="${KBS_MARK}" \
            2>/dev/null | grep -F '/kbs/v0/' | grep -Fv '127.0.0.1' || true)"

        if [ -n "${KBS_REQUESTS}" ]; then
            printf '%s\n' "${KBS_REQUESTS}"
            echo
            if printf '%s\n' "${KBS_REQUESTS}" | grep -q 'POST /kbs/v0/attest[^"]*" 200'; then
                ATTESTED="yes"
                echo "  ATTESTED. The guest POSTed an SEV-SNP report to /kbs/v0/attest"
                echo "  and the KBS verified it against AMD's cert chain."
                if printf '%s\n' "${KBS_REQUESTS}" \
                    | grep -q "GET /kbs/v0/resource/${KBS_SMOKE_PATH}[^\"]*\" 200"; then
                    echo "  It then fetched kbs:///${KBS_SMOKE_PATH}, so a resource was"
                    echo "  actually released to an attested guest - the full round trip."
                fi
            else
                echo "  The guest reached the KBS but did not complete an attestation."
            fi
        elif [ "${TEST_ATTESTATION}" != "1" ]; then
            echo "  Nothing, as expected: TEST_ATTESTATION=${TEST_ATTESTATION}."
        else
            echo "  NOTHING REACHED THE KBS."
        fi
    fi

    if [ "${KEEP_TEST_POD}" = "1" ]; then
        echo
        echo "KEEP_TEST_POD=1; leaving ${TEST_POD_NAME} running."
    else
        echo
        echo "Deleting ${TEST_POD_NAME}."
        "${KUBE[@]}" delete pod "${TEST_POD_NAME}" --ignore-not-found --wait --timeout=180s || true
    fi
fi

# --- 10. Summary ---

log "Summary"
printf '  %-28s %s\n' "daemon" "$(systemctl is-active cloud-api-adaptor.service)"
printf '  %-28s %s\n' "socket" "${CAA_SOCKET}"
printf '  %-28s %s\n' "pod VM size" "${PODVM_SIZE}"
printf '  %-28s %s\n' "pod VM confidential" "$([ "${DISABLECVM}" = "true" ] && echo no || echo "yes (SecurityType=ConfidentialVM, vTPM)")"
printf '  %-28s %s\n' "pod VM image" "$(sed -n 's/^AZURE_IMAGE_ID=//p' <(sudo cat "${PEERPODS_CONF_DIR}/peer-pods.env"))"
if [ "${USE_TRUSTEE}" = "1" ]; then
    printf '  %-28s %s\n' "KBS" "$("${KUBE[@]}" -n "${TRUSTEE_NS}" get \
        "deployment/${KBS_DEPLOYMENT}" \
        -o jsonpath='{.status.readyReplicas}/{.status.replicas} ready' 2>/dev/null \
        || echo unknown) at ${KBS_URL}"
    printf '  %-28s %s\n' "KBS deployed by" "trustee-operator in ${TRUSTEE_NS}"
    case "${ATTESTED}" in
        yes) printf '  %-28s %s\n' "guest attestation" "CONFIRMED by the KBS log" ;;
        no)  printf '  %-28s %s\n' "guest attestation" "NOT confirmed - see the KBS log above" ;;
        *)   printf '  %-28s %s\n' "guest attestation" "not tested (TEST_ATTESTATION=${TEST_ATTESTATION}, or no test pod)" ;;
    esac
else
    printf '  %-28s %s\n' "KBS" "not configured (USE_TRUSTEE=${USE_TRUSTEE})"
    printf '  %-28s %s\n' "guest attestation" "no"
fi
printf '  %-28s %s\n' "test pod" "${TEST_POD_RESULT}"

[ "${TEST_POD_RESULT}" = "failed" ] && exit 1
exit 0
REMOTE_SCRIPT
}

fail() { echo "ERROR: $*" >&2; exit 1; }

# --- Main Logic ---

command -v az > /dev/null 2>&1 || fail "the az CLI is not installed."
az account show > /dev/null 2>&1 || fail "not logged in to Azure. Run 'az login'."

# --- A. Discover the host's Azure context ---

echo "Looking up '${INSTANCE_NAME}' in resource group '${RESOURCE_GROUP}'..."
VM_JSON=$(az vm show --resource-group "${RESOURCE_GROUP}" --name "${INSTANCE_NAME}" \
    --show-details --output json 2>/dev/null) \
    || fail "could not find '${INSTANCE_NAME}'. Create it with 01_provision_fresh_vm.sh."

SUBSCRIPTION_ID=$(az account show --query id --output tsv)
AZURE_REGION=$(echo "${VM_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["location"])')
EXTERNAL_IP=$(echo "${VM_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("publicIps") or "")')
PRIVATE_IP=$(echo "${VM_JSON}" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("privateIps") or "").split(",")[0].strip())')
NIC_ID=$(echo "${VM_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["networkProfile"]["networkInterfaces"][0]["id"])')

SUBNET_ID=$(az network nic show --ids "${NIC_ID}" \
    --query "ipConfigurations[0].subnet.id" --output tsv)
SUBNET_CIDR=$(az network vnet subnet show --ids "${SUBNET_ID}" \
    --query "addressPrefix" --output tsv 2>/dev/null || true)
NSG_ID=$(az network nic show --ids "${NIC_ID}" \
    --query "networkSecurityGroup.id" --output tsv 2>/dev/null || true)
[ "${NSG_ID}" = "None" ] && NSG_ID=""

if [ -z "${EXTERNAL_IP}" ] && [ -f "${IP_FILE}" ]; then
    EXTERNAL_IP=$(cat "${IP_FILE}")
    echo "Falling back to cached address from ${IP_FILE}"
fi
[ -n "${EXTERNAL_IP}" ] || fail "could not determine the address of '${INSTANCE_NAME}'."

if [ "${USE_TRUSTEE}" = "1" ] && [ -z "${KBS_URL}" ]; then
    [ -n "${PRIVATE_IP}" ] \
        || fail "no private IP for '${INSTANCE_NAME}', so the pod VMs would have no address to attest to. Set KBS_URL, or USE_TRUSTEE=0."
fi

echo "  subscription   ${SUBSCRIPTION_ID}"
echo "  region         ${AZURE_REGION}"
echo "  subnet         ${SUBNET_ID##*/} (${SUBNET_CIDR:-unknown})"
echo "  nsg            ${NSG_ID:-(none)}"
echo "  host           ${ADMIN_USER}@${EXTERNAL_IP} (private ${PRIVATE_IP:-none})"
if [ "${USE_TRUSTEE}" = "1" ]; then
    echo "  KBS            ${KBS_URL:-http://${PRIVATE_IP}:<NodePort, assigned on the host>}"
else
    echo "  KBS            disabled (USE_TRUSTEE=${USE_TRUSTEE})"
fi

# --- B. Give the subnet an outbound path ---

echo
if [ "${PODVM_NAT_GATEWAY}" != "1" ]; then
    echo "Outbound: skipped (PODVM_NAT_GATEWAY=${PODVM_NAT_GATEWAY})."
else
    EXISTING_NAT=$(az network vnet subnet show --ids "${SUBNET_ID}" \
        --query "natGateway.id" --output tsv 2>/dev/null || true)
    [ "${EXISTING_NAT}" = "None" ] && EXISTING_NAT=""

    if [ -n "${EXISTING_NAT}" ]; then
        echo "Outbound: ${SUBNET_ID##*/} already routes through ${EXISTING_NAT##*/}."
    else
        echo "Outbound: giving ${SUBNET_ID##*/} a NAT gateway..."
        az network public-ip create --resource-group "${RESOURCE_GROUP}" \
            --name "${NAT_GATEWAY_IP_NAME}" --location "${AZURE_REGION}" \
            --sku Standard ${VM_TAGS[@]+--tags "${VM_TAGS[@]}"} --output none \
            || fail "could not create the NAT gateway's public IP '${NAT_GATEWAY_IP_NAME}'."
        az network nat gateway create --resource-group "${RESOURCE_GROUP}" \
            --name "${NAT_GATEWAY_NAME}" --location "${AZURE_REGION}" \
            --public-ip-addresses "${NAT_GATEWAY_IP_NAME}" \
            ${VM_TAGS[@]+--tags "${VM_TAGS[@]}"} --output none \
            || fail "could not create the NAT gateway '${NAT_GATEWAY_NAME}'."
        az network vnet subnet update --ids "${SUBNET_ID}" \
            --nat-gateway "${NAT_GATEWAY_NAME}" --output none \
            || fail "could not attach '${NAT_GATEWAY_NAME}' to ${SUBNET_ID##*/}."
        echo "          ${NAT_GATEWAY_NAME} attached."
    fi
fi

# --- C. Check the pod VM size is usable here ---

echo
echo "Checking ${PODVM_SIZE} in ${AZURE_REGION}..."
SKU_JSON=$(az vm list-skus --location "${AZURE_REGION}" --size "${PODVM_SIZE}" \
    --resource-type virtualMachines --output json 2>/dev/null || true)

if [ "$(echo "${SKU_JSON}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)" -eq 0 ]; then
    echo "ERROR: ${PODVM_SIZE} is not offered in ${AZURE_REGION}."
    exit 1
fi

CC_TYPE=$(echo "${SKU_JSON}" | python3 -c '
import json,sys
s = json.load(sys.stdin)[0]
caps = {c["name"]: c["value"] for c in s.get("capabilities") or []}
print(caps.get("ConfidentialComputingType", ""))' 2>/dev/null || true)
SKU_FAMILY=$(echo "${SKU_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("family",""))' 2>/dev/null || true)
RESTRICTED=$(echo "${SKU_JSON}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[0].get("restrictions") or []))' 2>/dev/null || echo 0)

echo "  confidential   ${CC_TYPE:-none}"
echo "  family         ${SKU_FAMILY}"

if [ "${DISABLE_CVM}" != "1" ] && [ -z "${CC_TYPE}" ]; then
    fail "${PODVM_SIZE} is not a confidential size."
fi
[ "${RESTRICTED}" -eq 0 ] || fail "${PODVM_SIZE} is restricted for this subscription in ${AZURE_REGION}."

QUOTA_LIMIT=$(az vm list-usage --location "${AZURE_REGION}" \
    --query "[?name.value=='${SKU_FAMILY}'].limit | [0]" --output tsv 2>/dev/null || true)
echo "  quota          ${QUOTA_LIMIT:-unknown} vCPUs"
if [ "${QUOTA_LIMIT:-0}" = "0" ]; then
    echo "ERROR: this subscription has no ${SKU_FAMILY} quota in ${AZURE_REGION}."
    [ "${SKIP_QUOTA_CHECK:-0}" = "1" ] || exit 1
fi

# --- D. Service principal ---

echo "Checking Azure credentials..."
SP_NAME="${INSTANCE_NAME}-peerpods"

if [ -n "${AZURE_CLIENT_ID:-}" ] && [ -n "${AZURE_CLIENT_SECRET:-}" ] && [ -n "${AZURE_TENANT_ID:-}" ]; then
    echo "Using the service principal from environment variables."
elif [ -s "${SP_FILE}" ]; then
    echo "Using the service principal cached in ${SP_FILE}"
    AZURE_CLIENT_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["appId"])' "${SP_FILE}")
    AZURE_CLIENT_SECRET=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["password"])' "${SP_FILE}")
    AZURE_TENANT_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tenant"])' "${SP_FILE}")
elif [ "${CREATE_SP}" = "1" ]; then
    EXISTING_APP_ID=$(az ad sp list --display-name "${SP_NAME}" --query "[0].appId" --output tsv 2>/dev/null || true)

    if [ -n "${EXISTING_APP_ID}" ]; then
        echo "Found existing service principal '${SP_NAME}' (App ID: ${EXISTING_APP_ID}). Resetting credentials into ${SP_FILE}..."
        az ad sp credential reset \
            --id "${EXISTING_APP_ID}" \
            --output json > "${SP_FILE}" || fail "could not reset credentials for service principal."
    else
        echo "Creating new service principal '${SP_NAME}'..."
        az ad sp create-for-rbac \
            --name "${SP_NAME}" \
            --role Contributor \
            --scopes "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}" \
            --output json > "${SP_FILE}" || fail "could not create service principal."
    fi

    chmod 600 "${SP_FILE}"
    AZURE_CLIENT_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["appId"])' "${SP_FILE}")
    AZURE_CLIENT_SECRET=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["password"])' "${SP_FILE}")
    AZURE_TENANT_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tenant"])' "${SP_FILE}")

    SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
    HAS_ROLE=$(az role assignment list --assignee "${AZURE_CLIENT_ID}" --scope "${SCOPE}" --role Contributor --query "[0].id" --output tsv 2>/dev/null || true)
    if [ -z "${HAS_ROLE}" ]; then
        echo "Assigning Contributor role on ${RESOURCE_GROUP}..."
        az role assignment create --assignee "${AZURE_CLIENT_ID}" --role Contributor --scope "${SCOPE}" --output none || true
        echo "Waiting 30s for role assignment to propagate..."
        sleep 30
    fi
else
    echo "ERROR: no Azure credentials for the daemon." >&2
    exit 1
fi

# --- E. Resolve the pod VM image ---

echo
COMMUNITY_IMAGE_ID="/CommunityGalleries/${COCO_COMMUNITY_GALLERY}/Images/${PODVM_IMAGE_DEF_SRC}/Versions/${PODVM_IMAGE_VER_SRC}"
PODVM_TARGET_REGIONS="${PODVM_SOURCE_REGION},${AZURE_REGION}"

if [ -n "${PODVM_IMAGE_ID}" ]; then
    echo "Using the pod VM image given in PODVM_IMAGE_ID:"
    echo "  ${PODVM_IMAGE_ID}"
else
    PODVM_LOCAL_VERSION=$(az sig image-version list \
        --resource-group "${RESOURCE_GROUP}" \
        --gallery-name "${PODVM_LOCAL_GALLERY}" \
        --gallery-image-definition "${PODVM_LOCAL_IMAGE_DEF}" \
        --query "sort_by([?provisioningState=='Succeeded'].{n:name,p:publishingProfile.publishedDate},&p)[-1].n" \
        --output tsv 2>/dev/null || true)
    [ "${PODVM_LOCAL_VERSION}" = "None" ] && PODVM_LOCAL_VERSION=""

    if [ -n "${PODVM_LOCAL_VERSION}" ]; then
        PODVM_GALLERY="${PODVM_LOCAL_GALLERY}"
        PODVM_IMAGE_DEF="${PODVM_LOCAL_IMAGE_DEF}"
        PODVM_IMAGE_VERSION="${PODVM_LOCAL_VERSION}"
        echo "Found a locally built pod VM image; preferring it over the community one."
    else
        echo "No image in ${PODVM_LOCAL_GALLERY}/${PODVM_LOCAL_IMAGE_DEF}; using community image."
    fi

    echo "Looking for ${PODVM_GALLERY}/${PODVM_IMAGE_DEF}/${PODVM_IMAGE_VERSION}..."
    PODVM_IMAGE_ID=$(az sig image-version show \
        --resource-group "${RESOURCE_GROUP}" \
        --gallery-name "${PODVM_GALLERY}" \
        --gallery-image-definition "${PODVM_IMAGE_DEF}" \
        --gallery-image-version "${PODVM_IMAGE_VERSION}" \
        --query id --output tsv 2>/dev/null || true)

    if [ -n "${PODVM_IMAGE_ID}" ]; then
        REPLICATED_REGIONS=$(az sig image-version show \
            --resource-group "${RESOURCE_GROUP}" \
            --gallery-name "${PODVM_GALLERY}" \
            --gallery-image-definition "${PODVM_IMAGE_DEF}" \
            --gallery-image-version "${PODVM_IMAGE_VERSION}" \
            --query "publishingProfile.targetRegions[].name" --output tsv 2>/dev/null \
            | tr -d ' ' | tr '[:upper:]' '[:lower:]' || true)

        if printf '%s\n' "${REPLICATED_REGIONS}" | grep -Fxq "${AZURE_REGION}"; then
            echo "  already imported, replicated to $(echo "${REPLICATED_REGIONS}" | paste -sd, -)"
        else
            echo "  adding ${AZURE_REGION} to replication targets..."
            TARGET_REGIONS=$(printf '%s\n%s\n' "${REPLICATED_REGIONS}" "${AZURE_REGION}" \
                | sort -u | tr '\n' ' ')
            # shellcheck disable=SC2086
            az sig image-version update \
                --resource-group "${RESOURCE_GROUP}" \
                --gallery-name "${PODVM_GALLERY}" \
                --gallery-image-definition "${PODVM_IMAGE_DEF}" \
                --gallery-image-version "${PODVM_IMAGE_VERSION}" \
                --target-regions ${TARGET_REGIONS} \
                --output none \
                || fail "could not replicate ${PODVM_IMAGE_VERSION} to ${AZURE_REGION}."
        fi
    else
        [ -n "${PODVM_LOCAL_VERSION}" ] \
            && fail "${PODVM_GALLERY}/${PODVM_IMAGE_DEF}/${PODVM_IMAGE_VERSION} was listed but cannot be read."
        echo "  not there; host will import it from ${PODVM_IMAGE_DEF_SRC} ${PODVM_IMAGE_VER_SRC}"
        az sig image-version show-community \
            --location "${PODVM_SOURCE_REGION}" \
            --public-gallery-name "${COCO_COMMUNITY_GALLERY}" \
            --gallery-image-definition "${PODVM_IMAGE_DEF_SRC}" \
            --gallery-image-version "${PODVM_IMAGE_VER_SRC}" \
            --query name --output tsv > /dev/null 2>&1 \
            || fail "community image ${COMMUNITY_IMAGE_ID} is not readable in ${PODVM_SOURCE_REGION}."
    fi
fi

# --- F. Reach the host ---

echo
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

DISABLECVM=$([ "${DISABLE_CVM}" = "1" ] && echo true || echo false)
USE_PUBLIC_IP_BOOL=$([ "${USE_PUBLIC_IP}" = "1" ] && echo true || echo false)

REMOTE_SCRIPT_FILE=$(mktemp -t setup-peerpods.XXXXXX)
CREDS_FILE=$(mktemp -t peerpods-creds.XXXXXX)
trap 'rm -f "${REMOTE_SCRIPT_FILE}" "${CREDS_FILE}"' EXIT

write_remote_script "${REMOTE_SCRIPT_FILE}"

chmod 600 "${CREDS_FILE}"
cat > "${CREDS_FILE}" <<EOF
AZURE_CLIENT_ID=${AZURE_CLIENT_ID}
AZURE_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
AZURE_TENANT_ID=${AZURE_TENANT_ID}
EOF

echo "Copying to the host..."
scp "${SSH_OPTS[@]}" -q "${REMOTE_SCRIPT_FILE}" \
    "${ADMIN_USER}@${EXTERNAL_IP}:/tmp/setup-peerpods.sh" \
    || fail "failed to copy script to host."
scp "${SSH_OPTS[@]}" -q "${CREDS_FILE}" \
    "${ADMIN_USER}@${EXTERNAL_IP}:/tmp/peer-pods-credentials.env" \
    || fail "failed to copy credentials to host."

echo
echo "Setting up peer pods on ${INSTANCE_NAME}"
[ -z "${PODVM_IMAGE_ID}" ] && echo "The pod VM image import alone takes about 15 minutes."
echo "------------------------------------------------------"
if ! ssh "${SSH_OPTS[@]}" -t "${ADMIN_USER}@${EXTERNAL_IP}" \
    "WORKSPACE='${WORKSPACE}' CAA_SRC='${CAA_SRC}' \
     AZURE_SUBSCRIPTION_ID='${SUBSCRIPTION_ID}' AZURE_REGION='${AZURE_REGION}' \
     AZURE_RESOURCE_GROUP='${RESOURCE_GROUP}' AZURE_SUBNET_ID='${SUBNET_ID}' \
     AZURE_NSG_ID='${NSG_ID}' PODVM_SIZE='${PODVM_SIZE}' \
     CREATE_CONTAINER_TIMEOUT='${CREATE_CONTAINER_TIMEOUT}' \
     SANDBOX_CGROUP_ONLY='${SANDBOX_CGROUP_ONLY}' \
     PODVM_IMAGE_ID='${PODVM_IMAGE_ID}' COMMUNITY_IMAGE_ID='${COMMUNITY_IMAGE_ID}' \
     PODVM_GALLERY='${PODVM_GALLERY}' PODVM_IMAGE_DEF='${PODVM_IMAGE_DEF}' \
     PODVM_IMAGE_VERSION='${PODVM_IMAGE_VERSION}' \
     PEERPODS_TAGS='${PEERPODS_TAGS}' \
     PODVM_SOURCE_REGION='${PODVM_SOURCE_REGION}' \
     PODVM_TARGET_REGIONS='${PODVM_TARGET_REGIONS}' \
     DISABLECVM='${DISABLECVM}' USE_PUBLIC_IP_BOOL='${USE_PUBLIC_IP_BOOL}' \
     CAA_EXTRA_ARGS='${CAA_EXTRA_ARGS}' RESTART_CRIO='${RESTART_CRIO}' \
     RUN_TEST_POD='${RUN_TEST_POD}' KEEP_TEST_POD='${KEEP_TEST_POD}' \
     TEST_POD_NAME='${TEST_POD_NAME}' TEST_IMAGE='${TEST_IMAGE}' \
     TEST_POD_TIMEOUT='${TEST_POD_TIMEOUT}' \
     USE_TRUSTEE='${USE_TRUSTEE}' TRUSTEE_OPERATOR_SRC='${TRUSTEE_OPERATOR_SRC}' \
     PRIVATE_IP='${PRIVATE_IP}' \
     TEST_ATTESTATION='${TEST_ATTESTATION}' KBS_SMOKE_PATH='${KBS_SMOKE_PATH}' \
     KBS_URL='${KBS_URL}' KBS_PORT='${KBS_PORT}' AA_KBC_PARAMS='${AA_KBC_PARAMS}' SUBNET_CIDR='${SUBNET_CIDR}' \
     bash /tmp/setup-peerpods.sh"; then
    echo "------------------------------------------------------"
    echo "ERROR: failed on '${INSTANCE_NAME}'." >&2
    exit 1
fi

# --- Tag the gallery the import created ---
GALLERY_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${PODVM_GALLERY}"
for TAG_TARGET in \
    "${GALLERY_ID}" \
    "${GALLERY_ID}/images/${PODVM_IMAGE_DEF}" \
    "${GALLERY_ID}/images/${PODVM_IMAGE_DEF}/versions/${PODVM_IMAGE_VERSION}"; do
    az tag update --operation merge --resource-id "${TAG_TARGET}" \
        ${VM_TAGS[@]+--tags "${VM_TAGS[@]}"} --output none 2>/dev/null \
        || echo "WARNING: could not tag ${TAG_TARGET#*/providers/Microsoft.Compute/}"
done

echo "------------------------------------------------------"
echo "Peer pods are up on ${INSTANCE_NAME}."
echo "Run a workload with 'runtimeClassName: kata-remote'."
#!/bin/bash

# Generates a sealed secret pointer using a JWK key pair, publishes the public key and
# raw secret to Trustee KBS, and deploys a Confidential Pod (kata-remote) to test
# in-guest unsealing.
#
# Prerequisites:
#   02_setup_peerpods.sh (Cloud API Adaptor & Trustee KBS active)
#
# usage: 03_setup_sealed_secret.sh [-c <config-file>] [<config-file>]

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

TEST_POD_NAME="${TEST_POD_NAME:-llm-sealed-env}"
TEST_POD_TIMEOUT="${TEST_POD_TIMEOUT:-600}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=15)
[ -f "${SSH_KEY}" ] && SSH_OPTS+=(-i "${SSH_KEY}")

# --- Functions ---

write_remote_script() {
    cat > "$1" <<'REMOTE_SCRIPT'
#!/bin/bash
# Configures and tests Sealed Secrets with Trustee KBS on this host.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
TEST_POD_NAME="${TEST_POD_NAME:-llm-sealed-env}"
TEST_POD_TIMEOUT="${TEST_POD_TIMEOUT:-600}"
CAA_SOCKET=/run/peerpod/hypervisor.sock
TRUSTEE_NS=trustee-operator-system
KBS_DEPLOYMENT=trustee-deployment
KBS_SERVICE=kbs-service
KUBECONFIG_PATH=/var/run/kubernetes/admin.kubeconfig
KUBECTL="${WORKSPACE}/kubernetes/_output/bin/kubectl"
COCO_TOOLS_IMAGE="quay.io/openshift_sandboxed_containers/coco-tools:0.5.1"

log() { echo; echo "=== $* ==="; }

k() {
    sudo -E "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" "$@"
}

# --- 0. Verify PeerPods and Trustee Prerequisites ---

log "Verifying 02_setup_peerpods.sh prerequisites"

if ! systemctl is-active --quiet cloud-api-adaptor.service; then
    echo "ERROR: cloud-api-adaptor.service is not running." >&2
    echo "Run 02_setup_peerpods.sh first." >&2
    exit 1
fi

if ! sudo test -S "${CAA_SOCKET}"; then
    echo "ERROR: CAA hypervisor socket ${CAA_SOCKET} not found." >&2
    echo "Run 02_setup_peerpods.sh first." >&2
    exit 1
fi

if ! sudo test -f "${KUBECONFIG_PATH}"; then
    echo "ERROR: Kubeconfig not found at ${KUBECONFIG_PATH}." >&2
    exit 1
fi

if ! k -n "${TRUSTEE_NS}" get deployment "${KBS_DEPLOYMENT}" >/dev/null 2>&1; then
    echo "ERROR: Trustee KBS deployment (${KBS_DEPLOYMENT}) not found in ${TRUSTEE_NS}." >&2
    echo "Run 02_setup_peerpods.sh with USE_TRUSTEE=1 first." >&2
    exit 1
fi

echo "  ok: cloud-api-adaptor and Trustee KBS are active."

if ! python3 -c "import cryptography" >/dev/null 2>&1; then
    log "Installing python3-cryptography..."
    sudo dnf install -y python3-cryptography
fi

# --- 1. Publish Raw Secret to Trustee ---

log "Publishing raw OpenAI API secret to Trustee (${TRUSTEE_NS})"
RAW_OPENAI_KEY="sk-proj-sealed-secret-super-secret-key-$(date +%s)"

k -n "${TRUSTEE_NS}" create secret generic openai \
    --from-literal="api-key=${RAW_OPENAI_KEY}" \
    --dry-run=client -o yaml | k apply -f -

# --- 2. Generate JWK Signing Keys ---

log "Generating JWK private and public signing keys"
export BASE_DIR="$HOME"
export SIGNING_DIR="$BASE_DIR/sealed-secrets"
mkdir -p "$SIGNING_DIR"
umask 077

python3 - <<'PY'
import base64
import json
import os
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric import ec

directory = Path(os.environ["SIGNING_DIR"])
key = ec.generate_private_key(ec.SECP256R1())
nums = key.private_numbers()

def b64url(n):
    return base64.urlsafe_b64encode(
        n.to_bytes(32, "big")
    ).rstrip(b"=").decode()

jwk = {
    "kty": "EC",
    "crv": "P-256",
    "alg": "ES256",
    "use": "sig",
    "kid": "sealed-signing",
    "d": b64url(nums.private_value),
    "x": b64url(nums.public_numbers.x),
    "y": b64url(nums.public_numbers.y),
}

for filename, value in [
    ("sealed-signing-private.json", jwk),
    ("sealed-signing-public.json", {k: v for k, v in jwk.items() if k != "d"}),
]:
    path = directory / filename
    path.write_text(json.dumps(value, indent=2))
    path.chmod(0o600)
PY

echo "  Saved private key to $SIGNING_DIR/sealed-signing-private.json"
echo "  Saved public key to $SIGNING_DIR/sealed-signing-public.json"

# --- 3. Register Public Key Secret in Trustee ---

log "Publishing signing public key to Trustee (${TRUSTEE_NS})"
k create secret generic sealed-signing-key \
  -n "${TRUSTEE_NS}" \
  --from-file="jwk_public=$SIGNING_DIR/sealed-signing-public.json" \
  --dry-run=client -o yaml | k apply -f -

# --- 4. Sync Secrets to KbsConfig and Recreate Trustee Pod ---

log "Updating KbsConfig resource list in ${TRUSTEE_NS}"
k -n "${TRUSTEE_NS}" get kbsconfig kbsconfig-peerpods -o json | \
python3 -c '
import json, sys
data = json.load(sys.stdin)
res = data["spec"].get("kbsSecretResources", [])
for name in ["sealed-signing-key", "openai"]:
    if name not in res:
        res.append(name)
data["spec"]["kbsSecretResources"] = res
print(json.dumps(data))
' | k apply -f -

log "Deleting Trustee KBS pod to force secret-converter init container reload"
KBS_PODS=$(k -n "${TRUSTEE_NS}" get pods -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep '^trustee-deployment' || true)
if [ -n "${KBS_PODS}" ]; then
    for p in ${KBS_PODS}; do
        k -n "${TRUSTEE_NS}" delete pod "${p}" --wait=false || true
    done
fi

log "Waiting for Trustee KBS rollout to complete..."
k -n "${TRUSTEE_NS}" rollout status "deployment/${KBS_DEPLOYMENT}" --timeout=180s

# Verify KBS Endpoint Resource Availability
KBS_NODEPORT="$(k -n "${TRUSTEE_NS}" get "service/${KBS_SERVICE}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
PRIVATE_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "127.0.0.1")

if [ -n "${KBS_NODEPORT}" ]; then
    log "Verifying KBS resource availability on http://${PRIVATE_IP}:${KBS_NODEPORT}"
    for RES_PATH in "default/sealed-signing-key/jwk_public" "default/openai/api-key"; do
        STATUS=404
        for ATTEMPT in $(seq 1 20); do
            STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://${PRIVATE_IP}:${KBS_NODEPORT}/kbs/v0/resource/${RES_PATH}" || echo 000)
            if [ "${STATUS}" != "404" ] && [ "${STATUS}" != "000" ]; then
                break
            fi
            sleep 2
        done
        echo "  resource ${RES_PATH}: HTTP ${STATUS}"
        if [ "${STATUS}" = "404" ]; then
            echo "ERROR: KBS returned 404 for ${RES_PATH}." >&2
            exit 1
        fi
    done
fi

# --- 5. Seal Secret Pointer via coco-tools ---

log "Pulling coco-tools container image (${COCO_TOOLS_IMAGE})"
sudo mkdir -p /podvm
sudo podman run --rm --root /podvm "${COCO_TOOLS_IMAGE}" --help >/dev/null 2>&1 || true

log "Sealing pointer via coco-tools container"
export POINTER
POINTER=$(
  sudo podman run --rm --root /podvm --security-opt label=disable \
    -v "$SIGNING_DIR/sealed-signing-private.json:/signing-key.json:Z" \
    "${COCO_TOOLS_IMAGE}" \
    secret seal \
    --signing-kid kbs:///default/sealed-signing-key/jwk_public \
    --signing-jwk-path /signing-key.json \
    vault \
    --resource-uri kbs:///default/openai/api-key \
    --provider kbs 2>/dev/null | grep -E '^sealed\.' | tr -d '\r\n'
)

if [ -z "${POINTER}" ]; then
    echo "ERROR: Failed to generate sealed secret pointer." >&2
    exit 1
fi

echo "Generated Sealed Pointer:"
echo "  ${POINTER}"

# --- 6. Verify Signature ---

log "Verifying Sealed Secret signature"
python3 - <<'PY'
import base64
import json
import os
from pathlib import Path
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils

def decode(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))

jwk = json.loads(
    (Path(os.environ["SIGNING_DIR"]) / "sealed-signing-public.json").read_text()
)
public_key = ec.EllipticCurvePublicNumbers(
    int.from_bytes(decode(jwk["x"]), "big"),
    int.from_bytes(decode(jwk["y"]), "big"),
    ec.SECP256R1(),
).public_key()

prefix, header, payload, signature = os.environ["POINTER"].split(".")
assert prefix == "sealed"
raw = decode(signature)
assert len(raw) == 64

der = utils.encode_dss_signature(
    int.from_bytes(raw[:32], "big"),
    int.from_bytes(raw[32:], "big"),
)
public_key.verify(
    der,
    f"{header}.{payload}".encode(),
    ec.ECDSA(hashes.SHA256()),
)
print("Signature verified successfully.")
PY

# --- 7. Publish Sealed Pointer to Default Namespace ---

log "Publishing openai-sealed secret in default namespace"
k create secret generic openai-sealed \
  -n default \
  --from-literal="llm-secrets=$POINTER" \
  --dry-run=client -o yaml | k apply -f -

unset POINTER

# --- 8. Create and Run Confidential Pod ---

log "Deploying Confidential Pod '${TEST_POD_NAME}'"

k delete pod "${TEST_POD_NAME}" -n default --ignore-not-found --wait --timeout=60s || true

cat <<EOF | k apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD_NAME}
  namespace: default
spec:
  runtimeClassName: kata-remote
  restartPolicy: Never
  containers:
    - name: app
      image: 'registry.access.redhat.com/ubi9/ubi-minimal:latest'
      imagePullPolicy: Always
      command:
        - /bin/sh
        - '-c'
      args:
        - |
          case "\$OPENAI_API_KEY" in
            "") echo "sealed-secret check: EMPTY"; exit 1 ;;
            sealed.*) echo "sealed-secret check: STILL_SEALED"; exit 1 ;;
            *) echo "sealed-secret check: UNSEALED" ;;
          esac
          sleep 10
      env:
        - name: OPENAI_API_KEY
          valueFrom:
            secretKeyRef:
              name: openai-sealed
              key: llm-secrets
              optional: false
EOF

echo "Waiting up to ${TEST_POD_TIMEOUT}s for '${TEST_POD_NAME}' execution..."
k wait --for=condition=Ready "pod/${TEST_POD_NAME}" -n default --timeout="${TEST_POD_TIMEOUT}s" || true

sleep 5

# --- 9. Display Pod Logs & Verify Unsealing ---

log "Logs from Confidential Pod '${TEST_POD_NAME}':"
echo "------------------------------------------------------"
POD_LOGS=$(k logs "${TEST_POD_NAME}" -n default 2>&1 || true)
echo "${POD_LOGS}"
echo "------------------------------------------------------"

if echo "${POD_LOGS}" | grep -q "sealed-secret check: UNSEALED"; then
    log "SUCCESS: Sealed secret unsealing verified!"
    echo "The pod successfully fetched the public key from Trustee, verified the"
    echo "signature, unsealed the secret URI, and retrieved the raw API key from KBS."
else
    echo "ERROR: Sealed secret check failed or did not report UNSEALED." >&2
    echo "Pod status:" >&2
    k describe pod "${TEST_POD_NAME}" -n default | tail -30 || true
    exit 1
fi

k delete pod "${TEST_POD_NAME}" -n default --ignore-not-found --wait || true
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

REMOTE_SCRIPT_FILE=$(mktemp -t setup-sealed-secret.XXXXXX)
trap 'rm -f "${REMOTE_SCRIPT_FILE}"' EXIT

write_remote_script "${REMOTE_SCRIPT_FILE}"

echo "Copying script to host..."
scp "${SSH_OPTS[@]}" -q "${REMOTE_SCRIPT_FILE}" \
    "${ADMIN_USER}@${EXTERNAL_IP}:/tmp/setup-sealed-secret.sh" \
    || fail "failed to copy script to host."

echo "Running Sealed Secret setup and verification on ${INSTANCE_NAME}..."
echo "------------------------------------------------------"
if ! ssh "${SSH_OPTS[@]}" -t "${ADMIN_USER}@${EXTERNAL_IP}" \
    "WORKSPACE='${WORKSPACE}' TEST_POD_NAME='${TEST_POD_NAME}' TEST_POD_TIMEOUT='${TEST_POD_TIMEOUT}' bash /tmp/setup-sealed-secret.sh"; then
    echo "------------------------------------------------------"
    echo "ERROR: Sealed secret setup or verification failed on '${INSTANCE_NAME}'." >&2
    exit 1
fi

echo "------------------------------------------------------"
echo "Sealed Secret test successfully executed on '${INSTANCE_NAME}'."
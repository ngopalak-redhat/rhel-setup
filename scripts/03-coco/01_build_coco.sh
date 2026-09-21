#!/bin/bash

# Clones and builds Confidential Containers repositories on the RHEL 9 host, under
# /workspace/confidential-containers/<repo>[cite: 8].
#
# usage: 01_build_coco.sh [-c <config-file>] [<config-file>]

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

COCO_REPOS="${COCO_REPOS:-confidential-containers trustee trustee-operator cloud-api-adaptor}"
COCO_ORG_URL="${COCO_ORG_URL:-https://github.com/confidential-containers}"

BUILD_TRUSTEE="${BUILD_TRUSTEE:-1}"
BUILD_TRUSTEE_OPERATOR="${BUILD_TRUSTEE_OPERATOR:-1}"
BUILD_CAA="${BUILD_CAA:-1}"
BUILD_DIAGRAMS="${BUILD_DIAGRAMS:-1}"

TRUSTEE_OPERATOR_IMAGE="${TRUSTEE_OPERATOR_IMAGE:-localhost/trustee-operator:dev}"
RUST_ROOT="${RUST_ROOT:-${WORKSPACE}/rust}"

KBS_AS_FEATURE="${KBS_AS_FEATURE:-coco-as-builtin}"
SGX_VERSION="${SGX_VERSION:-2.30}"
SGX_REPO_URL="${SGX_REPO_URL:-https://download.01.org/intel-sgx/sgx-linux}"
D2_VERSION="${D2_VERSION:-v0.8.1}"

# --- Pod VM image ---
BUILD_PODVM="${BUILD_PODVM:-1}"
PODVM_KATA_REF="${PODVM_KATA_REF:-}"
PODVM_LOCAL_AGENT="${PODVM_LOCAL_AGENT:-}"
PODVM_TEE_PLATFORM="${PODVM_TEE_PLATFORM:-az-cvm-vtpm}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-${WORKSPACE}/docker}"
CONTAINERD_DATA_ROOT="${CONTAINERD_DATA_ROOT:-${WORKSPACE}/containerd}"

# --- Publishing the pod VM image ---
PUBLISH_PODVM="${PUBLISH_PODVM:-1}"
PODVM_BUILD_GALLERY="${PODVM_BUILD_GALLERY:-${RESOURCE_GROUP}_podvm_local_gallery}"
PODVM_BUILD_IMAGE_DEF="${PODVM_BUILD_IMAGE_DEF:-podvm-local}"
PODVM_BUILD_IMAGE_VERSION="${PODVM_BUILD_IMAGE_VERSION:-0.$(date -u +%Y%m%d).$(date -u +%s)}"
PODVM_STORAGE_ACCOUNT="${PODVM_STORAGE_ACCOUNT:-${RESOURCE_GROUP}podvm}"
PODVM_STORAGE_CONTAINER="${PODVM_STORAGE_CONTAINER:-podvm}"
PODVM_IDENTITY_ROLE="${PODVM_IDENTITY_ROLE:-Contributor}"

DELETE_AFTER=$(date -u -v+3d +"%Y-%m-%d" 2>/dev/null || date -u -d "+3 days" +"%Y-%m-%d")

VM_TAGS=(
    "owner=${OWNER}"
    "delete-after=${DELETE_AFTER}"
)
PODVM_TAGS="${VM_TAGS[*]}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" -o ConnectTimeout=15)
[ -f "${SSH_KEY}" ] && SSH_OPTS+=(-i "${SSH_KEY}")

# --- Functions ---

write_remote_script() {
    cat > "$1" <<'REMOTE_SCRIPT'
#!/bin/bash
# Clones and builds Confidential Containers on this host. Safe to re-run.
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
COCO_REPOS="${COCO_REPOS:-confidential-containers trustee trustee-operator cloud-api-adaptor}"
COCO_ORG_URL="${COCO_ORG_URL:-https://github.com/confidential-containers}"
BUILD_TRUSTEE="${BUILD_TRUSTEE:-1}"
BUILD_TRUSTEE_OPERATOR="${BUILD_TRUSTEE_OPERATOR:-1}"
BUILD_CAA="${BUILD_CAA:-1}"
BUILD_DIAGRAMS="${BUILD_DIAGRAMS:-1}"
TRUSTEE_OPERATOR_IMAGE="${TRUSTEE_OPERATOR_IMAGE:-localhost/trustee-operator:dev}"
RUST_ROOT="${RUST_ROOT:-${WORKSPACE}/rust}"
KBS_AS_FEATURE="${KBS_AS_FEATURE:-coco-as-builtin}"
SGX_VERSION="${SGX_VERSION:-2.30}"
SGX_REPO_URL="${SGX_REPO_URL:-https://download.01.org/intel-sgx/sgx-linux}"
D2_VERSION="${D2_VERSION:-v0.8.1}"
BUILD_PODVM="${BUILD_PODVM:-1}"
PODVM_KATA_REF="${PODVM_KATA_REF:-}"
PODVM_LOCAL_AGENT="${PODVM_LOCAL_AGENT:-}"
PODVM_TEE_PLATFORM="${PODVM_TEE_PLATFORM:-az-cvm-vtpm}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-${WORKSPACE}/docker}"
CONTAINERD_DATA_ROOT="${CONTAINERD_DATA_ROOT:-${WORKSPACE}/containerd}"
KATA_SRC="${KATA_SRC:-${WORKSPACE}/kata-containers}"

PUBLISH_PODVM="${PUBLISH_PODVM:-1}"
PODVM_BUILD_GALLERY="${PODVM_BUILD_GALLERY:-${AZURE_RESOURCE_GROUP}_podvm_local_gallery}"
PODVM_BUILD_IMAGE_DEF="${PODVM_BUILD_IMAGE_DEF:-podvm-local}"
PODVM_BUILD_IMAGE_VERSION="${PODVM_BUILD_IMAGE_VERSION:-}"
PODVM_BUILD_LOCATION="${PODVM_BUILD_LOCATION:-}"
PODVM_STORAGE_ACCOUNT="${PODVM_STORAGE_ACCOUNT:-}"
PODVM_STORAGE_CONTAINER="${PODVM_STORAGE_CONTAINER:-podvm}"
PODVM_TAGS="${PODVM_TAGS:-owner=${OWNER}}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
COCO_ROOT="${WORKSPACE}/confidential-containers"
CRB_REPO="codeready-builder-for-rhel-9-x86_64-rhui-rpms"
RUN_USER="$(id -un)"

ARTIFACTS=()

log() { echo; echo "=== $* ==="; }

install_packages() {
    local description="$1"; shift
    local missing=()
    local pkg
    for pkg in "$@"; do
        rpm -q "${pkg}" > /dev/null 2>&1 || missing+=("${pkg}")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        log "${description} already installed; skipping dnf"
        return
    fi
    log "Installing ${description} (${#missing[@]} of $# missing)"
    sudo dnf install -y --enablerepo="${CRB_REPO}" "${missing[@]}"
}

# --- 0. Prerequisites ---

log "Checking prerequisites"
if ! command -v git > /dev/null 2>&1; then
    echo "ERROR: git is not installed."
    echo "Run 01_provision_fresh_vm.sh against this host first."
    exit 1
fi
echo "  ok: $(git --version)"

sudo mkdir -p "${COCO_ROOT}"
sudo chown "${RUN_USER}:${RUN_USER}" "${WORKSPACE}" "${COCO_ROOT}" 2>/dev/null || true

# --- 1. Fetch the source ---

fetch_repo() {
    local spec="$1"
    local name="${spec%%@*}"
    local ref=""
    [ "${spec}" != "${name}" ] && ref="${spec#*@}"
    local src="${COCO_ROOT}/${name}"

    log "Fetching ${name}"
    if [ -d "${src}/.git" ]; then
        echo "Repository already present; fetching updates."
        git -C "${src}" fetch --all --tags --prune
        git -C "${src}" merge --ff-only @{u} 2>/dev/null \
            || echo "Not fast-forwarded (local changes or a detached HEAD); tree left as is."
    else
        git clone "${COCO_ORG_URL}/${name}.git" "${src}"
    fi

    if [ -n "${ref}" ]; then
        echo "Checking out ${ref}"
        git -C "${src}" checkout "${ref}"
    fi

    if [ -f "${src}/.gitmodules" ]; then
        echo "Updating submodules."
        git -C "${src}" submodule update --init --recursive
    fi
}

for REPO_SPEC in ${COCO_REPOS}; do
    fetch_repo "${REPO_SPEC}"
done

# --- 2. Build ---

setup_go_env() {
    mkdir -p "${RUST_ROOT}/gopath" "${RUST_ROOT}/gocache" "${RUST_ROOT}/tmp"
    export TMPDIR="${RUST_ROOT}/tmp"
    export GOPATH="${RUST_ROOT}/gopath"
    export GOCACHE="${RUST_ROOT}/gocache"
    export PATH="${GOPATH}/bin:${PATH}"
    go version
}

ensure_yq() {
    if command -v yq > /dev/null 2>&1 && yq --version 2>&1 | grep -q 'v4'; then
        echo "yq: $(yq --version)"
    else
        echo "Installing yq v4 into ${GOPATH}/bin"
        go install github.com/mikefarah/yq/v4@latest
    fi
}

setup_rust_env() {
    sudo mkdir -p "${RUST_ROOT}/tmp" "${RUST_ROOT}/cargo" "${RUST_ROOT}/rustup"
    sudo chown -R "${RUN_USER}:${RUN_USER}" "${RUST_ROOT}"
    export TMPDIR="${RUST_ROOT}/tmp"
    export CARGO_HOME="${RUST_ROOT}/cargo"
    export RUSTUP_HOME="${RUST_ROOT}/rustup"
    if [ ! -x "${CARGO_HOME}/bin/cargo" ]; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path
    fi
    export PATH="${CARGO_HOME}/bin:${PATH}"
}

build_trustee() {
    local src="$1"

    install_packages "Trustee build dependencies" \
        perl perl-FindBin perl-lib perl-IPC-Cmd perl-File-Compare perl-File-Copy \
        pkgconf-pkg-config openssl-devel tpm2-tss-devel \
        clang clang-devel protobuf-compiler cmake tar gzip

    if rpm -q libsgx-dcap-quote-verify-devel > /dev/null 2>&1; then
        log "libsgx-dcap-quote-verify-devel already installed; skipping the Intel repo"
    else
        log "Installing libsgx-dcap-quote-verify-devel from Intel's repo"
        local sgx_dir="${WORKSPACE}/sgx"
        mkdir -p "${sgx_dir}"
        if [ ! -d "${sgx_dir}/sgx_rpm_local_repo" ]; then
            curl -fsSL -o "${sgx_dir}/sgx_rpm_local_repo.tgz" \
                "${SGX_REPO_URL}/${SGX_VERSION}/distro/centos-stream9/sgx_rpm_local_repo.tgz"
            tar -xaf "${sgx_dir}/sgx_rpm_local_repo.tgz" -C "${sgx_dir}"
        fi
        sudo dnf install -y --nogpgcheck \
            --repofrompath "sgx,file://${sgx_dir}/sgx_rpm_local_repo" \
            libsgx-dcap-quote-verify-devel
    fi

    log "Preparing the Rust toolchain in ${RUST_ROOT}"
    setup_rust_env
    local channel
    channel="$(sed -n 's/^channel[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' \
        "${src}/rust-toolchain.toml" 2>/dev/null)"
    if [ -n "${channel}" ]; then
        echo "rust-toolchain.toml pins ${channel}"
        rustup toolchain install "${channel}" --profile minimal
    fi
    (cd "${src}" && rustc --version && cargo --version)

    log "Building the KBS (AS_FEATURE=${KBS_AS_FEATURE})"
    make -C "${src}/kbs" AS_FEATURE="${KBS_AS_FEATURE}"

    log "Building the KBS client"
    make -C "${src}/kbs" cli

    log "Building the attestation service"
    make -C "${src}/attestation-service"

    log "Building the reference value provider service"
    make -C "${src}/rvps"

    local bin
    for bin in kbs kbs-client grpc-as restful-as rvps rvps-tool; do
        ARTIFACTS+=("trustee ${bin}|${src}/target/release/${bin}")
    done
}

build_trustee_operator() {
    local src="$1"

    install_packages "trustee-operator build dependencies" make gcc

    log "Preparing the Go environment"
    setup_go_env

    log "Building the trustee-operator manager"
    make -C "${src}" build
    ARTIFACTS+=("trustee-operator manager|${src}/bin/manager")

    log "Building the trustee-operator image as ${TRUSTEE_OPERATOR_IMAGE}"
    sudo podman build -t "${TRUSTEE_OPERATOR_IMAGE}" "${src}"

    if command -v crictl > /dev/null 2>&1 \
        && sudo crictl images 2>/dev/null | grep -q 'trustee-operator'; then
        echo "Visible to CRI-O: yes"
    else
        echo "WARNING: ${TRUSTEE_OPERATOR_IMAGE} is not visible through crictl."
        echo "         CRI-O will not be able to run it. Check that CRI-O's storage root"
        echo "         really is /var/lib/containers/storage:"
        echo "           grep -E '^\\s*root' /etc/crio/crio.conf /etc/crio/crio.conf.d/*"
    fi

    log "Generating the trustee-operator installer"
    make -C "${src}" build-installer IMG="${TRUSTEE_OPERATOR_IMAGE}"

    sed -i '/- name: OPERATOR_IMAGE_NAME/{n;s|value:.*|value: '"${TRUSTEE_OPERATOR_IMAGE}"'|;}' \
        "${src}/dist/install.yaml"
    echo "OPERATOR_IMAGE_NAME in dist/install.yaml:"
    grep -A1 'name: OPERATOR_IMAGE_NAME' "${src}/dist/install.yaml" | sed 's/^/  /'

    ARTIFACTS+=("trustee-operator installer|${src}/dist/install.yaml")

    git -C "${src}" checkout -- config/manager/kustomization.yaml 2>/dev/null || true

    echo
    echo "Image: ${TRUSTEE_OPERATOR_IMAGE} (in the root container store, not a registry)"
}

build_cloud_api_adaptor() {
    local src="$1/src/cloud-api-adaptor"

    install_packages "cloud-api-adaptor build dependencies" \
        libvirt-devel pkgconf-pkg-config gcc make

    log "Preparing the Go environment"
    setup_go_env
    ensure_yq

    log "Building cloud-api-adaptor"
    make -C "${src}" build

    local bin
    for bin in cloud-api-adaptor agent-protocol-forwarder process-user-data \
               az-copy-image azure-ready; do
        ARTIFACTS+=("cloud-api-adaptor ${bin}|${src}/${bin}")
    done
}

ensure_containerd_root() {
    local dropin_dir=/etc/systemd/system/containerd.service.d
    local old=/var/lib/containerd

    if pgrep -a containerd 2>/dev/null | grep -q -- "--root ${CONTAINERD_DATA_ROOT}"; then
        echo "containerd root: ${CONTAINERD_DATA_ROOT}"
        return
    fi

    log "Moving containerd's root out of /var"
    df -h /var | tail -1

    sudo mkdir -p "${dropin_dir}" "${CONTAINERD_DATA_ROOT}"
    sudo tee "${dropin_dir}/10-data-root.conf" > /dev/null <<EOF
# Written by 01_build_coco.sh.
[Service]
ExecStart=
ExecStart=/usr/bin/containerd --root ${CONTAINERD_DATA_ROOT}
EOF

    sudo systemctl stop docker.service docker.socket containerd.service

    if [ -n "$(sudo ls -A "${old}" 2>/dev/null)" ]; then
        echo "Copying $(sudo du -sh "${old}" | cut -f1) from ${old}..."
        sudo cp -a "${old}/." "${CONTAINERD_DATA_ROOT}/"
        sudo rm -rf "${old:?}"
        sudo mkdir -p "${old}"
    fi

    sudo systemctl daemon-reload
    sudo systemctl enable --now containerd.service
    sudo systemctl start docker.service
    df -h /var | tail -1
}

ensure_docker() {
    if rpm -q docker-ce > /dev/null 2>&1; then
        log "Docker already installed"
    else
        log "Installing Docker"
        sudo dnf install -y dnf-plugins-core
        sudo dnf config-manager --add-repo \
            https://download.docker.com/linux/rhel/docker-ce.repo
        sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    fi

    ensure_containerd_root

    sudo mkdir -p /etc/docker "${DOCKER_DATA_ROOT}"
    local daemon_json="{\"data-root\": \"${DOCKER_DATA_ROOT}\"}"
    if [ "$(sudo cat /etc/docker/daemon.json 2>/dev/null)" != "${daemon_json}" ]; then
        echo "${daemon_json}" | sudo tee /etc/docker/daemon.json > /dev/null
        sudo systemctl daemon-reload
        if sudo systemctl is-active --quiet docker; then
            sudo systemctl restart docker
        fi
    fi
    sudo systemctl enable --now docker

    if ! id -nG "${RUN_USER}" | tr ' ' '\n' | grep -qx docker; then
        echo "Adding ${RUN_USER} to the docker group"
        sudo usermod -aG docker "${RUN_USER}"
    fi
    sg docker -c 'docker version --format "client {{.Client.Version}}, server {{.Server.Version}}"'
}

podvm_agent_published() {
    local repo=kata-containers/cached-artefacts/agent token
    token=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2>/dev/null) \
        || return 1
    curl -fsS -o /dev/null \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json' \
        "https://ghcr.io/v2/${repo}/manifests/$1-$(uname -m)" 2>/dev/null
}

resolve_local_agent() {
    local want="${PODVM_LOCAL_AGENT}" tmp

    if [ "${want}" = "1" ]; then
        want="${KATA_SRC}/tools/packaging/kata-deploy/local-build/build/kata-static-agent.tar.zst"
        echo "PODVM_LOCAL_AGENT=1 -> ${want}" >&2
    fi

    if [ ! -f "${want}" ]; then
        echo "ERROR: PODVM_LOCAL_AGENT names no file: ${want}" >&2
        echo "Build one with:" >&2
        echo "  make -C ${KATA_SRC}/tools/packaging/kata-deploy/local-build agent-tarball" >&2
        exit 1
    fi

    case "${want}" in
    *.tar.zst)
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/podvm-agent.XXXXXX")"
        tar --zstd -xpf "${want}" -C "${tmp}" ./usr/bin/kata-agent >&2
        want="${tmp}/usr/bin/kata-agent"
        ;;
    esac

    if [ "$(head -c 4 "${want}")" != "$(printf '\177ELF')" ]; then
        echo "ERROR: ${want} is not an ELF binary." >&2
        exit 1
    fi

    echo "${want}"
}

build_podvm() {
    local repo="$1"
    local src="${repo}/src/cloud-api-adaptor"
    local podvm="${src}/podvm"
    local tree_agent="${podvm}/resources/binaries-tree/usr/local/bin/kata-agent"

    log "Preparing the pod VM image build"
    setup_go_env
    ensure_yq

    local agent=""
    if [ -n "${PODVM_LOCAL_AGENT}" ]; then
        agent="$(resolve_local_agent)"
        echo "Local agent: ${agent}"
        echo "  $(ls -l "${agent}" | awk '{print $5, $6, $7, $8}')"
    fi

    local ref="${PODVM_KATA_REF}"
    if [ -n "${ref}" ]; then
        echo "Agent commit from PODVM_KATA_REF: ${ref}"
    elif [ -n "${agent}" ]; then
        echo "versions.yaml left unpinned: the agent is coming from PODVM_LOCAL_AGENT."
    else
        if [ ! -d "${KATA_SRC}/.git" ]; then
            echo "ERROR: no Kata source at ${KATA_SRC} to take the agent commit from."
            echo "Run 02_build_kata.sh first, or set PODVM_KATA_REF."
            exit 1
        fi
        ref="$(git -C "${KATA_SRC}" rev-parse HEAD)"
        echo "Agent commit from ${KATA_SRC}: ${ref}"
        echo "  $(git -C "${KATA_SRC}" --no-pager log -1 --format='%h %ad %s' --date=short)"
    fi

    if [ -n "${ref}" ]; then
        if ! printf '%s' "${ref}" | grep -Eq '^[0-9a-f]{40}$'; then
            echo "ERROR: PODVM_KATA_REF must be a full 40-character lowercase commit SHA."
            echo "Got '${ref}'. Tags and short hashes are rejected by podvm/Makefile.inc."
            exit 1
        fi

        echo "Checking ghcr for a published agent artifact..."
        if podvm_agent_published "${ref}"; then
            echo "  ok: ghcr.io/kata-containers/cached-artefacts/agent:${ref}-$(uname -m)"
        else
            cat <<EOF

ERROR: no kata-agent artifact published for ${ref}.

Point PODVM_KATA_REF at a merged main commit, or build the agent from your tree:
  make -C ${KATA_SRC}/tools/packaging/kata-deploy/local-build agent-tarball
  PODVM_LOCAL_AGENT=1 BUILD_PODVM=1 ./01_build_coco.sh
EOF
            exit 1
        fi
    fi

    ensure_docker

    log "Building the pod VM image (TEE_PLATFORM=${PODVM_TEE_PLATFORM})"
    echo "This runs mkosi under buildkit and takes the better part of an hour."
    echo

    (
        if [ -n "${ref}" ]; then
            trap 'git -C "${repo}" checkout -- src/cloud-api-adaptor/versions.yaml' EXIT
            yq -i ".oci.kata-containers.reference = \"${ref}\"" "${src}/versions.yaml"
            echo "versions.yaml oci.kata-containers.reference -> ${ref}"
        fi

        export TEE_PLATFORM="${PODVM_TEE_PLATFORM}"

        if [ -z "${agent}" ]; then
            sg docker -c "make -C '${podvm}'"
        else
            sg docker -c "make -C '${podvm}' podvm-binaries"
            install -D -m 0755 "${agent}" "${tree_agent}"
            echo "Substituted the agent in the pod VM image:"
            echo "  ${agent}"
            echo "  -> ${tree_agent}"

            sg docker -c "make -C '${podvm}' image"
        fi
    )

    ARTIFACTS+=("podvm raw image|${podvm}/build/system.raw")
    ARTIFACTS+=("podvm qcow2|${podvm}/build/podvm-ubuntu-amd64.qcow2")
}

ensure_az() {
    if command -v az > /dev/null 2>&1; then
        echo "az: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
        return
    fi
    log "Installing the Azure CLI"
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo dnf install -y \
        https://packages.microsoft.com/config/rhel/9.0/packages-microsoft-prod.rpm
    sudo dnf install -y azure-cli
    az version --query '"azure-cli"' -o tsv
}

publish_podvm() {
    local repo="$1"
    local src="${repo}/src/cloud-api-adaptor"
    local azure="${src}/azure"
    local qcow2="${src}/podvm/build/podvm-ubuntu-amd64.qcow2"

    log "Publishing the pod VM image as ${PODVM_BUILD_IMAGE_VERSION}"

    local var
    for var in PODVM_BUILD_IMAGE_VERSION PODVM_BUILD_LOCATION PODVM_STORAGE_ACCOUNT \
               AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP; do
        if [ -z "${!var}" ]; then
            echo "ERROR: ${var} is unset; the laptop half should have passed it in."
            exit 1
        fi
    done

    if [ ! -f "${qcow2}" ]; then
        echo "ERROR: no pod VM image at ${qcow2}."
        echo "Build one first with BUILD_PODVM=1."
        exit 1
    fi

    ensure_az

    if az account show > /dev/null 2>&1; then
        echo "Already logged in to Azure."
    else
        echo "Logging in with this VM's managed identity"
        az login --identity -o none
    fi
    az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
    echo "Subscription: $(az account show --query name -o tsv)"

    local vhd="podvm-${PODVM_BUILD_IMAGE_VERSION//./_}.vhd"

    (
        trap 'make -C "${azure}" clean > /dev/null 2>&1 || true' EXIT
        : > "${azure}/podvm.tar.xz"
        cp "${qcow2}" "${azure}/podvm-ubuntu-amd64.qcow2"

        make -C "${azure}" image.vhd

        echo "Uploading ${vhd} ($(du -h "${azure}/image.vhd" | cut -f1))..."
        az storage blob upload \
            --account-name "${PODVM_STORAGE_ACCOUNT}" \
            --container-name "${PODVM_STORAGE_CONTAINER}" \
            --file "${azure}/image.vhd" \
            --name "${vhd}" \
            --overwrite \
            --only-show-errors --no-progress --output none

        local account_id blob_url
        account_id=$(az storage account show \
            --name "${PODVM_STORAGE_ACCOUNT}" \
            --resource-group "${AZURE_RESOURCE_GROUP}" \
            --query id --output tsv)
        blob_url=$(az storage blob url \
            --account-name "${PODVM_STORAGE_ACCOUNT}" \
            --container-name "${PODVM_STORAGE_CONTAINER}" \
            --name "${vhd}" --output tsv)

        local tags=()
        read -r -a tags <<< "${PODVM_TAGS}"

        echo "Creating image version ${PODVM_BUILD_IMAGE_VERSION} in ${PODVM_BUILD_LOCATION}..."
        az sig image-version create \
            ${tags[@]+--tags "${tags[@]}"} \
            --resource-group "${AZURE_RESOURCE_GROUP}" \
            --gallery-name "${PODVM_BUILD_GALLERY}" \
            --gallery-image-definition "${PODVM_BUILD_IMAGE_DEF}" \
            --gallery-image-version "${PODVM_BUILD_IMAGE_VERSION}" \
            --location "${PODVM_BUILD_LOCATION}" \
            --target-regions "${PODVM_BUILD_LOCATION}" \
            --os-vhd-storage-account "${account_id}" \
            --os-vhd-uri "${blob_url}" \
            --replication-mode Shallow \
            --only-show-errors \
            --output tsv --query id
    )
}

build_coco_diagrams() {
    local src="$1"

    log "Rendering the architecture diagrams"
    setup_go_env
    if ! command -v d2 > /dev/null 2>&1; then
        echo "Installing the d2 CLI ${D2_VERSION} into ${GOPATH}/bin"
        go install "github.com/d2lang/d2@${D2_VERSION}"
    fi
    d2 --version

    (
        cd "${src}"
        d2 diagrams/cc_tee_container.d2 images/CC_TEE_container.svg
        d2 diagrams/coco_v1_kata.d2 images/COCO_ccv1_TEE.svg
        d2 diagrams/coco_v1_peerpods.d2 images/COCO_ccv1_peerpods_TEE.svg
    )

    local img
    for img in CC_TEE_container COCO_ccv1_TEE COCO_ccv1_peerpods_TEE; do
        ARTIFACTS+=("diagram ${img}.svg|${src}/images/${img}.svg")
    done
}

for REPO_SPEC in ${COCO_REPOS}; do
    NAME="${REPO_SPEC%%@*}"
    SRC="${COCO_ROOT}/${NAME}"
    case "${NAME}" in
        trustee)
            if [ "${BUILD_TRUSTEE}" = "1" ]; then
                build_trustee "${SRC}"
            else
                log "Skipping the trustee build (BUILD_TRUSTEE=${BUILD_TRUSTEE})"
            fi
            ;;
        trustee-operator)
            if [ "${BUILD_TRUSTEE_OPERATOR}" = "1" ]; then
                build_trustee_operator "${SRC}"
            else
                log "Skipping the trustee-operator build (BUILD_TRUSTEE_OPERATOR=${BUILD_TRUSTEE_OPERATOR})"
            fi
            ;;
        cloud-api-adaptor)
            if [ "${BUILD_CAA}" = "1" ]; then
                build_cloud_api_adaptor "${SRC}"
            else
                log "Skipping the cloud-api-adaptor build (BUILD_CAA=${BUILD_CAA})"
            fi
            if [ "${BUILD_PODVM}" = "1" ]; then
                build_podvm "${SRC}"
            else
                log "Skipping the pod VM image build (BUILD_PODVM=${BUILD_PODVM})"
            fi
            if [ "${PUBLISH_PODVM}" = "1" ]; then
                publish_podvm "${SRC}"
            else
                log "Skipping the pod VM image publish (PUBLISH_PODVM=${PUBLISH_PODVM})"
            fi
            ;;
        confidential-containers)
            if [ "${BUILD_DIAGRAMS}" = "1" ]; then
                build_coco_diagrams "${SRC}"
            else
                log "Skipping the diagram render (BUILD_DIAGRAMS=${BUILD_DIAGRAMS})"
            fi
            ;;
        *)
            log "No build recipe for ${NAME}; cloned only"
            ;;
    esac
done

# --- 3. Report ---

log "Source trees"
for REPO_SPEC in ${COCO_REPOS}; do
    NAME="${REPO_SPEC%%@*}"
    SRC="${COCO_ROOT}/${NAME}"
    printf '  %-24s %-8s %-10s %s\n' \
        "${NAME}" \
        "$(du -sh "${SRC}" | cut -f1)" \
        "$(git -C "${SRC}" rev-parse --abbrev-ref HEAD)" \
        "$(git -C "${SRC}" --no-pager log -1 --format='%h %s' | cut -c1-60)"
done

if [ "${#ARTIFACTS[@]}" -eq 0 ]; then
    echo
    echo "Nothing was built."
else
    log "Artifacts"
    for ENTRY in "${ARTIFACTS[@]}"; do
        LABEL="${ENTRY%%|*}"
        PATH_="${ENTRY#*|}"
        if [ -e "${PATH_}" ]; then
            printf '  %-34s %-6s %s\n' "${LABEL}" \
                "$(du -h "${PATH_}" | cut -f1)" "${PATH_}"
        else
            printf '  %-34s %-6s %s\n' "${LABEL}" "MISSING" "${PATH_}"
        fi
    done
    echo
    echo "Nothing was installed into a system directory."
    if [ "${BUILD_TRUSTEE_OPERATOR}" = "1" ]; then
        echo
        echo "${TRUSTEE_OPERATOR_IMAGE} was written into the root container store."
    fi
fi
REMOTE_SCRIPT
}

prepare_podvm_publish() {
    if ! az account show > /dev/null 2>&1; then
        echo "ERROR: PUBLISH_PODVM=1 needs an Azure login here. Run 'az login'." >&2
        exit 1
    fi

    AZURE_SUBSCRIPTION_ID=$(az account show --query id --output tsv)

    PODVM_BUILD_LOCATION=$(az vm show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${INSTANCE_NAME}" \
        --query location --output tsv 2>/dev/null || true)
    if [ -z "${PODVM_BUILD_LOCATION}" ]; then
        echo "ERROR: could not read location of '${INSTANCE_NAME}'." >&2
        exit 1
    fi
    local location="${PODVM_BUILD_LOCATION}"
    echo "Publishing into ${location}, the host's own region."

    # 1. Identity assignment
    local principal
    principal=$(az vm show \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${INSTANCE_NAME}" \
        --query "identity.principalId" --output tsv 2>/dev/null || true)

    if [ -n "${principal}" ] && [ "${principal}" != "None" ]; then
        echo "System-assigned managed identity already present on '${INSTANCE_NAME}'; skipping assignment."
    else
        echo "Assigning a system-assigned managed identity to '${INSTANCE_NAME}'..."
        principal=$(az vm identity assign \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${INSTANCE_NAME}" \
            --query systemAssignedIdentity --output tsv 2>/dev/null || true)
        if [ -z "${principal}" ] || [ "${principal}" = "None" ]; then
            echo "ERROR: failed to assign managed identity to '${INSTANCE_NAME}'." >&2
            exit 1
        fi
    fi
    echo "Managed identity: ${principal}"

    # 2. Role assignment
    local scope="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}"
    if [ -n "$(az role assignment list --assignee "${principal}" --scope "${scope}" \
                   --role "${PODVM_IDENTITY_ROLE}" --query "[0].id" --output tsv 2>/dev/null || true)" ]; then
        echo "Identity already has ${PODVM_IDENTITY_ROLE} on ${RESOURCE_GROUP}."
    else
        echo "Granting ${PODVM_IDENTITY_ROLE} on ${RESOURCE_GROUP} to identity..."
        local assigned=0
        for ATTEMPT in 1 2 3 4 5 6; do
            if az role assignment create \
                --assignee-object-id "${principal}" \
                --assignee-principal-type ServicePrincipal \
                --role "${PODVM_IDENTITY_ROLE}" \
                --scope "${scope}" \
                --output none 2>/dev/null; then
                assigned=1
                break
            fi
            echo "  identity not replicated yet (attempt ${ATTEMPT}); retrying in 10s"
            sleep 10
        done
        if [ "${assigned}" -ne 1 ]; then
            echo "ERROR: could not grant ${PODVM_IDENTITY_ROLE} on ${RESOURCE_GROUP}." >&2
            exit 1
        fi
    fi

    # 3. Storage Account
    if az storage account show --resource-group "${RESOURCE_GROUP}" \
           --name "${PODVM_STORAGE_ACCOUNT}" --output none 2>/dev/null; then
        echo "Storage account ${PODVM_STORAGE_ACCOUNT} already exists."
    else
        echo "Creating storage account ${PODVM_STORAGE_ACCOUNT} in ${location}..."
        if ! az storage account create \
            --resource-group "${RESOURCE_GROUP}" \
            --name "${PODVM_STORAGE_ACCOUNT}" \
            --location "${location}" \
            --sku Standard_LRS --kind StorageV2 \
            --min-tls-version TLS1_2 \
            --allow-blob-public-access false \
            ${VM_TAGS[@]+--tags "${VM_TAGS[@]}"} \
            --output none; then
            echo "ERROR: failed to create '${PODVM_STORAGE_ACCOUNT}'." >&2
            exit 1
        fi
    fi

    az storage container create \
        --account-name "${PODVM_STORAGE_ACCOUNT}" \
        --name "${PODVM_STORAGE_CONTAINER}" \
        --output none || exit 1

    # 4. Gallery & Image Definition
    if ! az sig show --resource-group "${RESOURCE_GROUP}" \
             --gallery-name "${PODVM_BUILD_GALLERY}" --output none 2>/dev/null; then
        echo "Creating gallery ${PODVM_BUILD_GALLERY} in ${location}..."
        az sig create \
            --resource-group "${RESOURCE_GROUP}" \
            --gallery-name "${PODVM_BUILD_GALLERY}" \
            --location "${location}" \
            ${VM_TAGS[@]+--tags "${VM_TAGS[@]}"} \
            --output none || exit 1
    fi

    if ! az sig image-definition show --resource-group "${RESOURCE_GROUP}" \
             --gallery-name "${PODVM_BUILD_GALLERY}" \
             --gallery-image-definition "${PODVM_BUILD_IMAGE_DEF}" \
             --output none 2>/dev/null; then
        echo "Creating image definition ${PODVM_BUILD_IMAGE_DEF}..."
        az sig image-definition create \
            --resource-group "${RESOURCE_GROUP}" \
            --gallery-name "${PODVM_BUILD_GALLERY}" \
            --gallery-image-definition "${PODVM_BUILD_IMAGE_DEF}" \
            --location "${location}" \
            --publisher podvm-local --offer podvm --sku ubuntu \
            --os-type Linux --os-state generalized \
            --hyper-v-generation V2 \
            --features SecurityType=ConfidentialVmSupported \
            ${VM_TAGS[@]+--tags "${VM_TAGS[@]}"} \
            --output none || exit 1
    fi

    PODVM_PUBLISHED_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${PODVM_BUILD_GALLERY}/images/${PODVM_BUILD_IMAGE_DEF}/versions/${PODVM_BUILD_IMAGE_VERSION}"
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

AZURE_SUBSCRIPTION_ID=""
PODVM_BUILD_LOCATION=""
PODVM_PUBLISHED_ID=""
if [ "${PUBLISH_PODVM}" = "1" ]; then
    echo "------------------------------------------------------"
    echo "Preparing the pod VM image publish"
    prepare_podvm_publish
fi

REMOTE_SCRIPT_FILE=$(mktemp -t build-coco.XXXXXX)
trap 'rm -f "${REMOTE_SCRIPT_FILE}"' EXIT
write_remote_script "${REMOTE_SCRIPT_FILE}"

echo "Copying script to the host..."
if ! scp "${SSH_OPTS[@]}" -q "${REMOTE_SCRIPT_FILE}" \
    "${ADMIN_USER}@${EXTERNAL_IP}:/tmp/build-coco.sh"; then
    echo "ERROR: failed to copy script to host." >&2
    exit 1
fi

echo "Fetching on ${INSTANCE_NAME}: ${COCO_REPOS}"
if [ "${BUILD_TRUSTEE}" = "1" ]; then
    echo "Trustee will be built."
fi
if [ "${BUILD_TRUSTEE_OPERATOR}" = "1" ]; then
    echo "Trustee operator will be built as ${TRUSTEE_OPERATOR_IMAGE}."
fi
if [ "${BUILD_PODVM}" = "1" ]; then
    echo "Pod VM image will be built."
fi
if [ "${PUBLISH_PODVM}" = "1" ]; then
    echo "Image will be published as ${PODVM_BUILD_GALLERY}/${PODVM_BUILD_IMAGE_DEF}/${PODVM_BUILD_IMAGE_VERSION}."
fi
echo "------------------------------------------------------"

if ! ssh "${SSH_OPTS[@]}" -t "${ADMIN_USER}@${EXTERNAL_IP}" \
    "WORKSPACE='${WORKSPACE}' COCO_REPOS='${COCO_REPOS}' COCO_ORG_URL='${COCO_ORG_URL}' BUILD_TRUSTEE='${BUILD_TRUSTEE}' BUILD_TRUSTEE_OPERATOR='${BUILD_TRUSTEE_OPERATOR}' TRUSTEE_OPERATOR_IMAGE='${TRUSTEE_OPERATOR_IMAGE}' BUILD_CAA='${BUILD_CAA}' BUILD_DIAGRAMS='${BUILD_DIAGRAMS}' RUST_ROOT='${RUST_ROOT}' KBS_AS_FEATURE='${KBS_AS_FEATURE}' SGX_VERSION='${SGX_VERSION}' SGX_REPO_URL='${SGX_REPO_URL}' D2_VERSION='${D2_VERSION}' BUILD_PODVM='${BUILD_PODVM}' PODVM_KATA_REF='${PODVM_KATA_REF}' PODVM_LOCAL_AGENT='${PODVM_LOCAL_AGENT}' PODVM_TEE_PLATFORM='${PODVM_TEE_PLATFORM}' DOCKER_DATA_ROOT='${DOCKER_DATA_ROOT}' CONTAINERD_DATA_ROOT='${CONTAINERD_DATA_ROOT}' PUBLISH_PODVM='${PUBLISH_PODVM}' PODVM_BUILD_GALLERY='${PODVM_BUILD_GALLERY}' PODVM_BUILD_IMAGE_DEF='${PODVM_BUILD_IMAGE_DEF}' PODVM_BUILD_IMAGE_VERSION='${PODVM_BUILD_IMAGE_VERSION}' PODVM_BUILD_LOCATION='${PODVM_BUILD_LOCATION}' PODVM_STORAGE_ACCOUNT='${PODVM_STORAGE_ACCOUNT}' PODVM_STORAGE_CONTAINER='${PODVM_STORAGE_CONTAINER}' PODVM_TAGS='${PODVM_TAGS}' AZURE_SUBSCRIPTION_ID='${AZURE_SUBSCRIPTION_ID}' AZURE_RESOURCE_GROUP='${RESOURCE_GROUP}' bash /tmp/build-coco.sh"; then
    echo "------------------------------------------------------"
    echo "ERROR: failed on '${INSTANCE_NAME}'." >&2
    exit 1
fi

echo "------------------------------------------------------"
echo "Source under ${WORKSPACE}/confidential-containers/"
echo "SSH: ssh ${ADMIN_USER}@${EXTERNAL_IP}"
if [ "${PUBLISH_PODVM}" = "1" ]; then
    echo
    echo "Pod VM image published. Hand it to the peer pods setup with:"
    echo "  PODVM_IMAGE_ID='${PODVM_PUBLISHED_ID}' ./02_setup_peerpods.sh"
fi
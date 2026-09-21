# Azure RHEL 9 CRI-O / Kubernetes / Kata / CoCo Pipeline

A modular automation pipeline to provision an Azure RHEL 9 VM into a confidential computing development environment. The pipeline compiles and configures **CRI-O**, launches a local **Kubernetes** cluster (`local-up-cluster.sh`), compiles **Kata Containers**, and builds **Confidential Containers (CoCo)** with **PeerPods** (Cloud API Adaptor).

Every script runs **from your local machine** and executes remote tasks over SSH. Scripts automatically resolve the host IP via the Azure CLI or fall back to `~/<instance-name>-external-ip`.

All scripts are **idempotent**. Re-running a script refreshes source trees and updates configurations safely.

---

## Directory Structure & Pipeline Order

The repository is organized into three sequential phases plus a shared configuration folder. Commands below assume these directories are under `scripts/` and are run from the repository root.

```text
scripts/
├── config/
│   └── global.env                   # Shared global environment settings
├── 01-infra/                        # Phase 1: Infrastructure & VM Lifecycle
│   ├── 01_provision_fresh_vm.sh      # Create fresh Azure RHEL 9 VM
│   ├── 02_create_vm_image.sh         # Create managed backup image of the VM
│   ├── 03_restore_from_image.sh      # Restore/start VM from the latest image
│   └── 99_teardown_vm.sh             # Destroy host VM and core infra
├── 02-k8s-kata/                     # Phase 2: Kubernetes & Kata Stack
│   ├── 01_setup_k8s_crio.sh          # Install CRI-O, Kubernetes & crun
│   ├── 02_build_kata.sh              # Fetch and build Kata Containers
│   └── 03_install_kata.sh            # Install Kata binaries & configure CRI-O
└── 03-coco/                         # Phase 3: Confidential Containers & PeerPods
    ├── 01_build_coco.sh              # Build Trustee, CAA & Pod VM images
    ├── 02_setup_peerpods.sh          # Deploy Trustee Operator, CAA & PeerPods
    ├── 99_teardown_coco.sh           # Teardown CoCo galleries, SP & Pod VMs
    └── testCoCo.yaml                 # Sample Confidential Pod manifest
```

---

## Configuration & Environment Variables

All scripts automatically source `config/global.env`. You can also supply a custom configuration file via the `-c` or `--config` flag:

```bash
./scripts/01-infra/01_provision_fresh_vm.sh -c /path/to/custom.env

# OR pass it as a positional argument:
./scripts/01-infra/01_provision_fresh_vm.sh /path/to/custom.env
```

### Required Variables

These variables must be defined in your environment or configuration file:

| Variable | Description | Example |
| --- | --- | --- |
| `RESOURCE_GROUP` | Azure Resource Group for all deployment resources | `my-resource-group` |
| `OWNER` | Owner email used for tracking and resource tags | `user@example.com` |

### Key Optional Variables (with Defaults)

| Variable | Default | Description |
| --- | --- | --- |
| `INSTANCE_NAME` | `${RESOURCE_GROUP}-azure-host` | Name of the primary Azure host VM |
| `ADMIN_USER` | `core` | SSH admin username on the host VM |
| `SSH_KEY` | `${HOME}/.ssh/id_rsa` | Path to your SSH private key |
| `WORKSPACE` | `/workspace` | Remote directory on the host where builds take place |
| `PODVM_SIZE` | `Standard_DC2as_v5` | Azure Confidential VM size for PeerPod instances |
| `BUILD_PODVM` | `1` | Build local Pod VM image in `03-coco/01_build_coco.sh` (`0` to skip) |
| `PUBLISH_PODVM` | `1` | Publish Pod VM image to Azure Compute Gallery (`0` to skip) |
| `CREATE_SP` | `1` | Auto-create/reset Service Principal in `03-coco/02_setup_peerpods.sh` |
| `USE_TRUSTEE` | `1` | Deploy Trustee Attestation Service in `03-coco/02_setup_peerpods.sh` |
| `TEST_ATTESTATION` | `1` | Verify guest attestation with Trustee during smoke test |
| `START_CLUSTER` | `1` | Start `local-up-cluster.sh` in `02-k8s-kata/01_setup_k8s_crio.sh` |
| `RESTART_CRIO` | `1` | Restart `crio.service` to apply new drop-ins |

## Execution Guide

### Phase 1: Infrastructure & VM Lifecycle

#### 1. Provision a Fresh Host VM

```bash
./scripts/01-infra/01_provision_fresh_vm.sh [VM_SIZE] [-l LOCATION]
```

- **Default Size:** `Standard_D8s_v5` (8 vCPUs required for Kata builds; nested virtualization enabled).
- **Default Region:** `centralindia` (provides unrestricted Confidential VM quota).
- **Behavior:** Configures a 120 GB OS disk, public IP, NSG, and writes the host IP to `~/<instance-name>-external-ip`.

#### 2. Backup and Restore

```bash
# Create a managed backup image of the running host VM:
./scripts/01-infra/02_create_vm_image.sh

# Restore or recreate the host VM from the latest backup image:
./scripts/01-infra/03_restore_from_image.sh
```

### Phase 2: Kubernetes & Kata Containers

#### 1. Setup CRI-O and Kubernetes Cluster

```bash
./scripts/02-k8s-kata/01_setup_k8s_crio.sh
```

- Installs system dependencies, CodeReady Builder, `crun`, and `container-selinux`.
- Compiles CRI-O from source and runs it under systemd.
- Clones Kubernetes, builds etcd, and starts `local-up-cluster.sh` in the background.
- Runs a sample pod smoke test to confirm the cluster is operational.

#### 2. Build Kata Containers

```bash
./scripts/02-k8s-kata/02_build_kata.sh
```

- **Build only:** Does not touch `/etc` or `/opt`. Output lands under `/workspace`.
- Builds the Rust toolchain, Go runtime/shim, guest rootfs (via Podman/osbuilder), guest image, and guest kernel.
- Uses a dedicated Podman image store at `/workspace/containers` to preserve `/var` disk space.

#### 3. Install Kata & Configure CRI-O

```bash
./scripts/02-k8s-kata/03_install_kata.sh
```

- Installs kernel and binaries to `/opt/kata` and `/usr/share/kata-containers`.
- Writes CRI-O drop-ins (`/etc/crio/crio.conf.d/50-kata`) and mount propagation rules.
- Registers the `kata` RuntimeClass in Kubernetes.
- Runs a sample Kata pod and verifies that `uname -r` inside the pod differs from the host kernel.

### Phase 3: Confidential Containers & PeerPods

#### 1. Build CoCo Stack & Pod VM Image

```bash
./scripts/03-coco/01_build_coco.sh
```

- Clones and builds Trustee (KBS, AS, RVPS), Trustee Operator, and Cloud API Adaptor (CAA).
- Builds the Pod VM image using mkosi under Docker (`BUILD_PODVM=1`).
- Publishes the Pod VM image to an Azure Compute Gallery (`${RESOURCE_GROUP}_podvm_local_gallery`) using the VM's managed identity (`PUBLISH_PODVM=1`).

#### 2. Setup PeerPods & Deploy Attestation

```bash
./scripts/03-coco/02_setup_peerpods.sh
```

- Configures or reuses the Service Principal (`${INSTANCE_NAME}-peerpods`) for Azure API access.
- Attaches a NAT Gateway to the host subnet for Pod VM egress.
- Deploys the Trustee Operator and Key Broker Service (KBS) inside the cluster.
- Configures the Cloud API Adaptor daemon (`cloud-api-adaptor.service`) and writes CRI-O drop-in `60-kata-remote`.
- Registers the `kata-remote` RuntimeClass.
- Launches a test PeerPod, verifies CVM creation, and confirms full TEE attestation against Trustee.

## Teardown & Resource Cleanup

### Clean Up CoCo & PeerPods Resources Only

To delete Pod VMs, NAT Gateways, Compute Galleries, Storage Accounts, and Service Principals created in Phase 3 without destroying the host VM:

```bash
./scripts/03-coco/99_teardown_coco.sh
```

### Full Host & Infrastructure Teardown

To delete the primary host VM, attached disks, NICs, Public IPs, NSGs, and VNETs (while preserving backup images tagged with `keep-because`):

```bash
./scripts/01-infra/99_teardown_vm.sh
```

## Host Quick-Reference Commands

Run `scripts/00_env.sh` to get access to the Kubernetes cluster.

Log in to the host VM over SSH (replace `your-instance-name` with the actual instance name):

```bash
ssh core@"$(cat ~/your-instance-name-external-ip)"
```

Inside the host VM, load environment paths and run kubectl:

```bash
source ~/rhel_host_env.sh
```

Run a workload with the Kata RuntimeClass:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nginx-kata
spec:
  runtimeClassName: kata
  containers:
    - name: nginx
      image: nginx
      imagePullPolicy: IfNotPresent
EOF
```

Verify the guest kernel:

```bash
kubectl exec nginx-kata -- uname -r
```

To use PeerPods, set `runtimeClassName: kata-remote` in the pod manifest. The supplied sample manifest can be applied from a location where the repository is available and kubectl is configured:

```bash
kubectl apply -f scripts/03-coco/testCoCo.yaml
```

## Common Caveats & Tips

> Editorial note: The end of the supplied text was scrambled. The sample pod above was reconstructed from its identifiable YAML fields. The remaining fragments mention mount propagation, image pull policy, firewalld, IPv4-only CNI configuration, and PeerPod egress to Trustee/KBS, but their original instructions could not be reliably recovered.

# Environment for the Azure RHEL host provisioned by configure_azure_rhel_instance.sh.
# Copy it to the host and source it:
#
#   source ~/rhel_host_env.sh
#
# WORKSPACE must match the value the provisioning script ran with (default /workspace).

WORKSPACE="${WORKSPACE:-/workspace}"

# _output/bin            kubectl and the other Kubernetes binaries built by local-up-cluster.sh
# third_party/etcd       etcd and etcdctl installed by hack/install-etcd.sh
# /usr/local/bin         crio, crun and crictl installed by 'make install'
export PATH="${WORKSPACE}/kubernetes/_output/bin:${WORKSPACE}/kubernetes/third_party/etcd:/usr/local/bin:${PATH}"

# Credentials written by local-up-cluster.sh. The file is root-owned, so
# non-root kubectl calls need 'sudo -E kubectl ...'.
export KUBECONFIG=/var/run/kubernetes/admin.kubeconfig

# Shorthand, guarded so sourcing this on a Mac by accident leaves the local
# kubectl setup alone. Aliases only expand in interactive shells; scripts should
# keep calling kubectl directly.
if [ "$(uname -s)" = "Linux" ]; then
    alias k=kubectl
fi

#!/bin/bash
# Prepare node for Kubernetes: images, kubeadm/kubelet. Cluster is initialized on first boot via k8s-first-boot.service.
set -e

if [ -z "${CLOUD_PIPELINE_DISTRO_DIR:-}" ]; then
  echo "WARNING: CLOUD_PIPELINE_DISTRO_DIR is not set, falling back to /var/lib/cloud-pipeline/deploy" >&2
  CLOUD_PIPELINE_DISTRO_DIR="/var/lib/cloud-pipeline/deploy"
fi

_CP_BUILD_VERSION=$(tr -d '[:space:]' < "${CLOUD_PIPELINE_DISTRO_DIR}/helm/CP_BUILD_VERSION.txt")

systemctl start docker || { journalctl -xeu docker.service --no-pager >&2; journalctl -xeu containerd.service --no-pager >&2; exit 1; }
mkdir -p "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images" && \
wget -q "https://cloud-pipeline-oss-builds.s3.amazonaws.com/tools/kube/1.15.4/docker/calico-node-v3.14.1.tar" -O "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/calico-node-v3.14.1.tar" && \
wget -q "https://cloud-pipeline-oss-builds.s3.amazonaws.com/tools/kube/1.15.4/docker/calico-pod2daemon-flexvol-v3.14.1.tar" -O "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/calico-pod2daemon-flexvol-v3.14.1.tar" && \
wget -q "https://cloud-pipeline-oss-builds.s3.amazonaws.com/tools/kube/1.15.4/docker/calico-cni-v3.14.1.tar" -O "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/calico-cni-v3.14.1.tar" && \
wget -q "https://cloud-pipeline-oss-builds.s3.amazonaws.com/tools/kube/1.15.4/docker/k8s.gcr.io-kube-proxy-v1.15.4.tar" -O "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/k8s.gcr.io-kube-proxy-v1.15.4.tar" && \
wget -q "https://cloud-pipeline-oss-builds.s3.amazonaws.com/tools/kube/1.15.4/docker/ghcr.io-flannel-io-flannel-v0.26.4.tar" -O "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/ghcr.io-flannel-io-flannel-v0.26.4.tar" && \
wget -q "https://cloud-pipeline-oss-builds.s3.amazonaws.com/tools/kube/1.15.4/docker/k8s.gcr.io-pause-3.1.tar" -O "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/k8s.gcr.io-pause-3.1.tar"

docker load -i "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/calico-node-v3.14.1.tar" && \
docker load -i "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/calico-pod2daemon-flexvol-v3.14.1.tar" && \
docker load -i "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/calico-cni-v3.14.1.tar" && \
docker load -i "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/k8s.gcr.io-kube-proxy-v1.15.4.tar" && \
docker load -i "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/ghcr.io-flannel-io-flannel-v0.26.4.tar" && \
docker load -i "${CLOUD_PIPELINE_DISTRO_DIR}/docker-system-images/k8s.gcr.io-pause-3.1.tar"

systemctl stop docker

mkdir -p /etc/docker
if [ -n "${DOCKER_DATA_ROOT:-}" ]; then
  cat > /etc/docker/daemon.json <<EOT
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2"
}
EOT
else
  cat > /etc/docker/daemon.json <<'EOT'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2"
}
EOT
fi

wget -q --no-check-certificate https://cloud-pipeline-oss-builds.s3.amazonaws.com/tools/kube/1.15.4/rpm/kube-1.15.4.el7.tgz -O kube.tgz && \
     tar -xf kube.tgz && \
     cd kube && yum localinstall -y *kube*.rpm *cri-tools*.rpm && \
     cd .. && rm -rf kube/ kube.tgz

systemctl daemon-reload
systemctl enable docker
systemctl enable kubelet
systemctl start docker
systemctl start kubelet

for _bootstrap in kubeadm-init-config.yaml.raw canal.yaml.raw; do
  if [ ! -f "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/${_bootstrap}" ]; then
    echo "ERROR: missing ${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/${_bootstrap} (Packer file provisioner failed?)" >&2
    exit 1
  fi
done
export CP_KUBE_FLANNEL_CIDR="${CP_KUBE_FLANNEL_CIDR:-10.244.0.0/16}"
export CP_KUBE_NODE_CIDR_MASK="${CP_KUBE_NODE_CIDR_MASK:-26}"
export CP_KUBE_KUBELET_PORT="${CP_KUBE_KUBELET_PORT:-10250}"
envsubst '${CP_KUBE_FLANNEL_CIDR} ${CP_KUBE_KUBELET_PORT} ${CP_KUBE_NODE_CIDR_MASK}' < "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/kubeadm-init-config.yaml.raw" > "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/kubeadm-init-config.yaml"
envsubst '${CP_KUBE_FLANNEL_CIDR}' < "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/canal.yaml.raw" > "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/canal.yaml"

sed -i "s|__CP_DNS_HOSTS_SYNC_IMAGE__|${CP_DNS_HOSTS_SYNC_IMAGE}|" "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/patch-kube-dns.sh"
chmod +x "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/patch-kube-dns.sh"

# Configure the node via EC2 user data by appending to bootstrap.env:
#
#   #!/bin/bash
#   cat >> "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/bootstrap.env" <<'EOF'
#   ROLE=application-node          # omit or set "master-node" for the control plane node
#   CP_STORAGE_ID=fs-xxxxxxxxxxxxxxxxx
#   EOF
#
cat << 'BOOTSTRAPENV' > "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/bootstrap.env"
# Node role: "master-node" (default when unset) or "application-node".
# ROLE=application-node
#
# EFS or Lustre filesystem ID to mount at /opt.
# For EFS:
# CP_STORAGE_TYPE=efs
# CP_STORAGE_ID=fs-xxxxxxxxxxxxxxxxx
# For Lustre:
# CP_STORAGE_TYPE=lustre
# CP_STORAGE_LUSTRE_DNS=fs-xxxxxxxxxxxxxxxxx.fsx.regions.amazonaws.com
# CP_STORAGE_LUSTRE_MOUNT=x1x12xx
#
# Number of application-nodes to wait for.
# When set, master-node removes join credentials from EFS as soon as all application-nodes
# have joined instead of waiting for the 2h timer.
# The timer still fires as a fallback if not all application-nodes join in time.
# APPLICATION_NODE_COUNT=1
#
# Extra node labels applied to application-nodes at kubelet registration time (comma-separated).
# cloud-pipeline/application-node=true is always set and cannot be overridden here.
# CP_APPLICATION_NODE_LABELS=cloud-pipeline/cp-api-srv=true
#
# Node labels applied to the master-node after kubeadm init (comma-separated key=value pairs).
# When set, only these labels are applied (cloud-pipeline/region is always set regardless).
# When unset, the full default set of service labels is applied.
# CP_MASTER_NODE_LABELS=cloud-pipeline/cp-api-srv=true,cloud-pipeline/cp-edge=true
#
# Node selector label (key=value) used to pin kube-dns pods to a specific node.
# Default: node-role.kubernetes.io/master=
# KUBE_DNS_NODE_SELECTOR_LABEL=node-role.kubernetes.io/master=
BOOTSTRAPENV

# First-boot script: run kubeadm init (master-node) or kubeadm join (application-node)
cat << 'K8SBOOT' > /usr/local/bin/k8s-first-boot.sh
#!/bin/bash
set -e

source /etc/environment 2>/dev/null || true
if [ -z "${CLOUD_PIPELINE_DISTRO_DIR:-}" ]; then
  echo "WARNING: CLOUD_PIPELINE_DISTRO_DIR not found in /etc/environment, falling back to /var/lib/cloud-pipeline/deploy" >&2
  CLOUD_PIPELINE_DISTRO_DIR="/var/lib/cloud-pipeline/deploy"
fi

_BOOTSTRAP_ENV=${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/bootstrap.env
if [ -f "$_BOOTSTRAP_ENV" ]; then
  source "$_BOOTSTRAP_ENV"
fi

CP_STORAGE_MOUNTED=0
CP_STORAGE_TYPE="${CP_STORAGE_TYPE:-efs}"
if [ "${CP_STORAGE_TYPE}" == "efs" ]; then
  if [ -n "${CP_STORAGE_ID:-}" ]; then
    mount -t efs -o tls "${CP_STORAGE_ID}:/" /opt
    echo "EFS ${CP_STORAGE_ID} mounted at /opt"
    if ! grep -q "${CP_STORAGE_ID}" /etc/fstab; then
      echo "${CP_STORAGE_ID}:/ /opt efs _netdev,tls 0 0" >> /etc/fstab
    fi
    CP_STORAGE_MOUNTED=1
  else
    echo "CP_STORAGE_ID not set; skipping core EFS mount"
  fi
elif [ "${CP_STORAGE_TYPE}" == "lustre" ]; then
  if [ -n "${CP_STORAGE_LUSTRE_DNS}" ] && [ -n "${CP_STORAGE_LUSTRE_MOUNT}" ]; then
    _lustre_mount_url="${CP_STORAGE_LUSTRE_DNS}@tcp:/${CP_STORAGE_LUSTRE_MOUNT}"
    mount -t lustre "$_lustre_mount_url" /opt -o defaults,noatime,flock,_netdev
    echo "Lustre ${_lustre_mount_url} mounted at /opt"
    if ! grep -q "${_lustre_mount_url}" /etc/fstab; then
      echo "${_lustre_mount_url} /opt lustre defaults,noatime,flock,_netdev 0 0" >> /etc/fstab
    fi
    CP_STORAGE_MOUNTED=1
  else
    echo "CP_STORAGE_LUSTRE_DNS and/or CP_STORAGE_LUSTRE_MOUNT not set; skipping core Lustre mount"
  fi
fi

if [ "${ROLE:-master-node}" = "application-node" ]; then
  if [ -f /etc/kubernetes/kubelet.conf ]; then
    echo "Node already joined, skipping first-boot join"
    exit 0
  fi

  _KUBE_JOIN_SECRETS_DIR="/opt/.temp_kube_join"
  _KUBE_JOIN_SECRETS_ENV="${_KUBE_JOIN_SECRETS_DIR}/join.env"
  _KUBE_JOIN_SECRETS_READY="${_KUBE_JOIN_SECRETS_DIR}/ready.txt"
  _KUBE_JOIN_POLL_INTERVAL=10
  _KUBE_JOIN_TIMEOUT="${CP_KUBE_JOIN_TIMEOUT:-600}"
  _KUBE_JOIN_ITERATIONS=$(( _KUBE_JOIN_TIMEOUT / _KUBE_JOIN_POLL_INTERVAL ))
  echo "Waiting up to ${_KUBE_JOIN_TIMEOUT}s for master-node to write join credentials to EFS (${_KUBE_JOIN_SECRETS_READY})..."
  for _i in $(seq 1 "$_KUBE_JOIN_ITERATIONS"); do
    [ -f "$_KUBE_JOIN_SECRETS_READY" ] && break
    sleep "$_KUBE_JOIN_POLL_INTERVAL"
  done
  if [ ! -f "$_KUBE_JOIN_SECRETS_READY" ]; then
    echo "WARNING: timed out after ${_KUBE_JOIN_TIMEOUT}s waiting for ${_KUBE_JOIN_SECRETS_READY}" >&2
    echo "  Possible causes: master-node not yet initialized, shared filesysted mount to /opt failed on master-node" >&2
    echo "  Continuing — join will fail below if credentials are still missing" >&2
  fi
  if [ -f "$_KUBE_JOIN_SECRETS_ENV" ]; then
    echo "Sourcing join credentials from EFS: ${_KUBE_JOIN_SECRETS_ENV}"
    source "$_KUBE_JOIN_SECRETS_ENV"
  else
    echo "WARNING: ${_KUBE_JOIN_SECRETS_ENV} not found on EFS — kubeadm join will fail" >&2
  fi

  # Set node labels via kubelet dropin before join so they are applied at node registration time.
  # CP_APPLICATION_NODE_LABELS can be set in bootstrap.env to override the default extra labels.
  _CP_APPLICATION_NODE_LABELS="${CP_APPLICATION_NODE_LABELS:-cloud-pipeline/cp-api-srv=true}"
  _CP_APPLICATION_NODE_LABELS_VALID=true
  IFS=',' read -ra _label_list <<< "$_CP_APPLICATION_NODE_LABELS"
  for _label in "${_label_list[@]}"; do
    _label_key="${_label%%=*}"
    _label_val="${_label#*=}"
    if [ "$_label_key" = "$_label" ]; then
      echo "WARNING: CP_APPLICATION_NODE_LABELS: '${_label}' is missing '=' separator, skipping" >&2
      _CP_APPLICATION_NODE_LABELS_VALID=false
      continue
    fi
    if ! echo "$_label_key" | grep -qE '^([a-zA-Z0-9][a-zA-Z0-9._-]{0,251}[a-zA-Z0-9]/)?[a-zA-Z0-9][a-zA-Z0-9._-]{0,61}[a-zA-Z0-9]$|^[a-zA-Z0-9]$'; then
      echo "WARNING: CP_APPLICATION_NODE_LABELS: key '${_label_key}' contains invalid characters or format, skipping" >&2
      _CP_APPLICATION_NODE_LABELS_VALID=false
      continue
    fi
    if [ -n "$_label_val" ] && ! echo "$_label_val" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,61}[a-zA-Z0-9]$|^[a-zA-Z0-9]$'; then
      echo "WARNING: CP_APPLICATION_NODE_LABELS: value '${_label_val}' for key '${_label_key}' contains invalid characters, skipping" >&2
      _CP_APPLICATION_NODE_LABELS_VALID=false
      continue
    fi
  done
  if [ "$_CP_APPLICATION_NODE_LABELS_VALID" = false ]; then
    echo "WARNING: CP_APPLICATION_NODE_LABELS has invalid entries; falling back to default 'cloud-pipeline/cp-api-srv=true'" >&2
    _CP_APPLICATION_NODE_LABELS="cloud-pipeline/cp-api-srv=true"
  fi
  echo "KUBELET_EXTRA_ARGS=--node-labels=cloud-pipeline/application-node=true,${_CP_APPLICATION_NODE_LABELS}" \
    >> /etc/sysconfig/kubelet
  systemctl daemon-reload

  # --node-name is intentionally omitted: on AL2023 kubeadm defaults to the EC2
  # private DNS hostname (ip-x-x-x-x.region.compute.internal), which is unique
  # and resolvable within the VPC — no override needed.
  kubeadm join "$K8S_JOIN_ENDPOINT" \
    --token "$K8S_JOIN_TOKEN" \
    --discovery-token-ca-cert-hash "$K8S_JOIN_CA_CERT_HASH" \
    --ignore-preflight-errors=all

  # Point DNS at kube-dns ClusterIP so in-cluster names resolve on this node.
  KUBE_CLUSTER_DNS="${K8S_DNS_IP:-10.96.0.10}"
  if [ -f /etc/systemd/resolved.conf ] && \
     systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; then
    if grep -qE '^[[:space:]]*#DNS=' /etc/systemd/resolved.conf; then
      sed -i "s/^[[:space:]]*#DNS=.*/DNS=${KUBE_CLUSTER_DNS}/" /etc/systemd/resolved.conf
    elif grep -qE '^[[:space:]]*DNS=' /etc/systemd/resolved.conf; then
      sed -i "s/^[[:space:]]*DNS=.*/DNS=${KUBE_CLUSTER_DNS}/" /etc/systemd/resolved.conf
    else
      awk -v d="DNS=${KUBE_CLUSTER_DNS}" \
        '/^\[Resolve\]/ { print; print d; next } { print }' \
        /etc/systemd/resolved.conf > /tmp/resolved.conf.new \
        && mv /tmp/resolved.conf.new /etc/systemd/resolved.conf
    fi
    systemctl restart systemd-resolved || true
  elif ! grep -q "nameserver ${KUBE_CLUSTER_DNS}" /etc/resolv.conf 2>/dev/null; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    sed -i '/^nameserver/d' /etc/resolv.conf
    echo "nameserver ${KUBE_CLUSTER_DNS}" >> /etc/resolv.conf
  fi

  if [ -f "${_KUBE_JOIN_SECRETS_DIR}/admin.conf" ]; then
    mkdir -p /root/.kube
    cp "${_KUBE_JOIN_SECRETS_DIR}/admin.conf" /root/.kube/config
    chmod 600 /root/.kube/config
    echo "Kubeconfig copied from EFS ${_KUBE_JOIN_SECRETS_DIR}/admin.conf"
  else
    echo "WARNING: ${_KUBE_JOIN_SECRETS_DIR}/admin.conf not found; skipping kubeconfig copy" >&2
  fi

  exit 0
fi

# master-node path (ROLE=master-node or unset)
if [ -f /etc/kubernetes/pki/ca.crt ]; then
  echo "Kubernetes already initialized, skipping first-boot init"
  exit 0
fi
kubeadm init --config "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/kubeadm-init-config.yaml" --ignore-preflight-errors=all

mkdir -p /root/.kube
\cp /etc/kubernetes/admin.conf /root/.kube/config

# Write join credentials to EFS so application-nodes can bootstrap automatically.
# Layout: /opt/.temp_kube_join/join.env   (sourceable env file with join vars)
#         /opt/.temp_kube_join/admin.conf (cluster-admin kubeconfig for the application-node)
#         /opt/.temp_kube_join/ready.txt  (written last; signals files are safe to read)
if [ "${CP_STORAGE_MOUNTED}" -eq 1 ]; then
  _KUBE_JOIN_SECRETS_DIR="/opt/.temp_kube_join"
  mkdir -p "$_KUBE_JOIN_SECRETS_DIR"
  chmod 700 "$_KUBE_JOIN_SECRETS_DIR"

  # --print-join-command computes token, CA hash, and endpoint in one shot.
  # Output format: kubeadm join <endpoint> --token <token> --discovery-token-ca-cert-hash sha256:<hash>
  _JOIN_CMD="$(kubeadm token create --print-join-command --ttl 24h)"
  _MASTER_NODE_ENDPOINT="$(echo "$_JOIN_CMD" | awk '{print $3}')"
  _JOIN_TOKEN="$(echo "$_JOIN_CMD"      | sed 's/.*--token \([^ ]*\).*/\1/')"
  _CA_HASH="$(echo "$_JOIN_CMD"         | sed 's/.*--discovery-token-ca-cert-hash \([^ ]*\).*/\1/')"

  cat > "$_KUBE_JOIN_SECRETS_DIR/join.env" <<EOF
K8S_JOIN_ENDPOINT=${_MASTER_NODE_ENDPOINT}
K8S_JOIN_TOKEN=${_JOIN_TOKEN}
K8S_JOIN_CA_CERT_HASH=${_CA_HASH}
EOF
  chmod 600 "$_KUBE_JOIN_SECRETS_DIR/join.env"

  # Application-nodes copy this directly — no SSH needed.
  cp /root/.kube/config "$_KUBE_JOIN_SECRETS_DIR/admin.conf"
  chmod 644 "$_KUBE_JOIN_SECRETS_DIR/admin.conf"
  # Signal to application-nodes that all join files are fully written and safe to read.
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_KUBE_JOIN_SECRETS_DIR/ready.txt"
  echo "Join credentials written to EFS at ${_KUBE_JOIN_SECRETS_DIR}/join.env"

  cat > /usr/local/bin/kube-join-watcher.sh <<EOF
#!/bin/bash
_APPLICATION_NODE_COUNT=${APPLICATION_NODE_COUNT:-0}
_EXPECTED_TOTAL=\$(( _APPLICATION_NODE_COUNT + 1 ))
_DIR=${_KUBE_JOIN_SECRETS_DIR}
_TIMEOUT=7200
_POLL=10
_elapsed=0

_do_cleanup() {
  if [ -f "\$_DIR/join.env" ]; then
    _token=\$(grep '^K8S_JOIN_TOKEN=' "\$_DIR/join.env" | cut -d= -f2-)
    _token_id=\${_token%%.*}
    if [ -n "\$_token_id" ]; then
      kubectl delete secret "bootstrap-token-\${_token_id}" -n kube-system 2>/dev/null \
        && echo "kube-join-watcher: deleted bootstrap token \${_token_id}" \
        || echo "WARNING: kube-join-watcher: failed to delete bootstrap token \${_token_id}" >&2
    fi
  fi
  rm -rf "\$_DIR"
}

while [ \$_elapsed -lt \$_TIMEOUT ]; do
  if [ "\$_APPLICATION_NODE_COUNT" -gt 0 ]; then
    _joined=\$(kubectl get nodes -l cloud-pipeline/application-node=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "\$_joined" -ge "\$_EXPECTED_TOTAL" ]; then
      echo "kube-join-watcher: all \$_APPLICATION_NODE_COUNT application-node(s) joined the master-node — removing \$_DIR"
      _do_cleanup
      exit 0
    fi
  fi
  sleep \$_POLL
  _elapsed=\$(( _elapsed + _POLL ))
done

if [ "\$_APPLICATION_NODE_COUNT" -gt 0 ]; then
  _joined=\$(kubectl get nodes -l cloud-pipeline/application-node=true --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "WARNING: kube-join-watcher: 2h elapsed — only \$_joined/\$_EXPECTED_TOTAL node(s) joined; removing \$_DIR anyway" >&2
else
  echo "kube-join-watcher: 2h elapsed — removing \$_DIR"
fi
_do_cleanup
EOF
  chmod +x /usr/local/bin/kube-join-watcher.sh

  systemctl start kube-join-watcher.service || echo "WARNING: kube-join-watcher failed to start; join credentials will remain on EFS until manual cleanup" >&2
  if [ -n "${APPLICATION_NODE_COUNT:-}" ] && [ "${APPLICATION_NODE_COUNT}" -gt 0 ] 2>/dev/null; then
    echo "Join credential watcher started (expecting ${APPLICATION_NODE_COUNT} application-node(s))"
  else
    echo "Join credential watcher started (APPLICATION_NODE_COUNT not set; will clean up after 2h)"
  fi
else
  echo "Shared filesystem is not mounted, see mount errors above; skipping join credential generation"
fi

kubectl apply -f "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/canal.yaml"

_KUBE_DNS_NODE_SELECTOR_LABEL="${KUBE_DNS_NODE_SELECTOR_LABEL:-node-role.kubernetes.io/master=}"
_KUBE_DNS_NODE_SELECTOR_KEY="${_KUBE_DNS_NODE_SELECTOR_LABEL%%=*}"
_KUBE_DNS_NODE_SELECTOR_VALUE="${_KUBE_DNS_NODE_SELECTOR_LABEL#*=}"
kubectl label nodes --all "${_KUBE_DNS_NODE_SELECTOR_KEY}=${_KUBE_DNS_NODE_SELECTOR_VALUE}" --overwrite

"${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap/patch-kube-dns.sh" --node-selector-label="${_KUBE_DNS_NODE_SELECTOR_LABEL}" --dns-hosts-sync-image-version="__CP_DNS_HOSTS_SYNC_IMAGE_VERSION__"

echo "Wait for kube-dns Service ClusterIP to be available"
for _i in $(seq 1 60); do
  KUBE_CLUSTER_DNS=$(kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  [ -n "$KUBE_CLUSTER_DNS" ] && break
  sleep 2
done
KUBE_CLUSTER_DNS="${KUBE_CLUSTER_DNS:-10.96.0.10}"

if [ -f /etc/systemd/resolved.conf ]; then
  if grep -qE '^[[:space:]]*#DNS=' /etc/systemd/resolved.conf; then
    sed -i "s/^[[:space:]]*#DNS=.*/DNS=${KUBE_CLUSTER_DNS}/" /etc/systemd/resolved.conf
  elif grep -qE '^[[:space:]]*DNS=' /etc/systemd/resolved.conf; then
    sed -i "s/^[[:space:]]*DNS=.*/DNS=${KUBE_CLUSTER_DNS}/" /etc/systemd/resolved.conf
  else
    awk -v d="DNS=${KUBE_CLUSTER_DNS}" '/^\[Resolve\]/ { print; print d; next } { print }' /etc/systemd/resolved.conf > /tmp/resolved.conf.new \
      && mv /tmp/resolved.conf.new /etc/systemd/resolved.conf
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved\.service'; then
    systemctl restart systemd-resolved || true
  fi
fi

kubectl create clusterrolebinding owner-cluster-admin-binding \
    --clusterrole cluster-admin \
    --user system:serviceaccount:default:default

for _i in $(seq 1 90); do
  if kubectl get nodes --request-timeout=10s -o name 2>/dev/null | grep -q '^node/'; then
    break
  fi
  sleep 2
done
kubectl label nodes --all "cloud-pipeline/region=__CP_NODE_REGION__" --overwrite

if [ -n "${CP_MASTER_NODE_LABELS:-}" ]; then
  _CP_MASTER_NODE_LABELS_VALID=true
  IFS=',' read -ra _label_list <<< "$CP_MASTER_NODE_LABELS"
  for _label in "${_label_list[@]}"; do
    _label_key="${_label%%=*}"
    _label_val="${_label#*=}"
    if [ "$_label_key" = "$_label" ]; then
      echo "WARNING: CP_MASTER_NODE_LABELS: '${_label}' is missing '=' separator, skipping" >&2
      _CP_MASTER_NODE_LABELS_VALID=false
      continue
    fi
    if ! echo "$_label_key" | grep -qE '^([a-zA-Z0-9][a-zA-Z0-9._-]{0,251}[a-zA-Z0-9]/)?[a-zA-Z0-9][a-zA-Z0-9._-]{0,61}[a-zA-Z0-9]$|^[a-zA-Z0-9]$'; then
      echo "WARNING: CP_MASTER_NODE_LABELS: key '${_label_key}' contains invalid characters or format, skipping" >&2
      _CP_MASTER_NODE_LABELS_VALID=false
      continue
    fi
    if [ -n "$_label_val" ] && ! echo "$_label_val" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,61}[a-zA-Z0-9]$|^[a-zA-Z0-9]$'; then
      echo "WARNING: CP_MASTER_NODE_LABELS: value '${_label_val}' for key '${_label_key}' contains invalid characters, skipping" >&2
      _CP_MASTER_NODE_LABELS_VALID=false
      continue
    fi
  done
  if [ "$_CP_MASTER_NODE_LABELS_VALID" = false ]; then
    echo "WARNING: CP_MASTER_NODE_LABELS has invalid entries; falling back to default labels" >&2
    CP_MASTER_NODE_LABELS=""
  fi
fi

if [ -n "${CP_MASTER_NODE_LABELS:-}" ]; then
  echo "Applying custom master-node labels: ${CP_MASTER_NODE_LABELS}"
  IFS=',' read -ra _label_list <<< "$CP_MASTER_NODE_LABELS"
  for _label in "${_label_list[@]}"; do
    kubectl label nodes --all "$_label" --overwrite
  done
else
  kubectl label nodes --all cloud-pipeline/cp-api-srv=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-edge=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-idp=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-docker-registry=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-api-db=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-git=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-gitlab-db=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-git-sync=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-gitlab-reader=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-notifier=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-clair=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-docker-comp=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-search-elk-curator=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-search-elk=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-search-srv=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-heapster-elk=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-heapster=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-vm-monitor=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-monitoring-srv=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-billing-srv=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-redis=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-storage-lifecycle-service=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-dav=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-share-srv=true --overwrite
  kubectl label nodes --all cloud-pipeline/cp-run-policy-manager=true --overwrite
  kubectl label nodes --all cloud-pipeline/application-node=true --overwrite
  
fi

sed -i '/- kube-apiserver/a \    \- --service-node-port-range=80-32767' /etc/kubernetes/manifests/kube-apiserver.yaml
K8SBOOT

echo "CP_CLOUD_PIPELINE_NODE_REGION: $CP_CLOUD_PIPELINE_NODE_REGION"
sed -i "s/__CP_NODE_REGION__/${CP_CLOUD_PIPELINE_NODE_REGION}/" /usr/local/bin/k8s-first-boot.sh
sed -i "s/__CP_DNS_HOSTS_SYNC_IMAGE_VERSION__/${_CP_BUILD_VERSION}/" /usr/local/bin/k8s-first-boot.sh
chmod +x /usr/local/bin/k8s-first-boot.sh

# Systemd unit: run once after network is up
cat << 'K8SSVC' > /etc/systemd/system/k8s-first-boot.service
[Unit]
Description=Kubernetes first-boot init (kubeadm init)
After=network-online.target docker.service kubelet.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
ExecStart=/usr/local/bin/k8s-first-boot.sh
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
K8SSVC
cat > /etc/systemd/system/kube-join-watcher.service <<'WATCHERSVC'
[Unit]
Description=Watch for all Kubernetes application-nodes to join then clean up join credentials

[Service]
Type=simple
Environment=KUBECONFIG=/root/.kube/config
ExecStart=/usr/local/bin/kube-join-watcher.sh
WATCHERSVC

systemctl daemon-reload
systemctl enable k8s-first-boot.service

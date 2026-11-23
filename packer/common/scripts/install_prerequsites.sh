#!/bin/bash

if [ -z "${CLOUD_PIPELINE_DISTRO_DIR:-}" ]; then
  echo "WARNING: CLOUD_PIPELINE_DISTRO_DIR is not set, falling back to /var/lib/cloud-pipeline/deploy" >&2
  CLOUD_PIPELINE_DISTRO_DIR="/var/lib/cloud-pipeline/deploy"
fi

yum install -y \
            wget \
            git \
            gettext \
            iproute-tc \
            iptables \
            openssl \
            tar 
            
wget -q "https://cloud-pipeline-oss-builds.s3.amazonaws.com/tools/jq/jq-1.6/jq-linux64" -O /usr/bin/jq
chmod +x /usr/bin/jq

_DOCKER_TGZ_URL="https://cloud-pipeline-oss-builds.s3.amazonaws.com/tools/docker/distr/linux/static/stable/x86_64/docker-20.10.24.tgz"
wget -q "$_DOCKER_TGZ_URL" -O /tmp/docker.tgz || { echo "ERROR: failed to download Docker from $_DOCKER_TGZ_URL"; exit 1; }
tar -xzf /tmp/docker.tgz -C /tmp
cp /tmp/docker/* /usr/bin/
rm -rf /tmp/docker /tmp/docker.tgz

groupadd docker 2>/dev/null || true

# cri-dockerd: CRI shim in front of dockerd, so kubelet (dockershim removed since 1.24)
# can keep using the real Docker engine — preserves commit/pause/DinD scripts that call
# dockerd directly.
_CRI_DOCKERD_VERSION="0.4.10"
_CRI_DOCKERD_TGZ_URL="https://github.com/Mirantis/cri-dockerd/releases/download/v${_CRI_DOCKERD_VERSION}/cri-dockerd-${_CRI_DOCKERD_VERSION}.amd64.tgz"
wget -q "$_CRI_DOCKERD_TGZ_URL" -O /tmp/cri-dockerd.tgz || { echo "ERROR: failed to download cri-dockerd from $_CRI_DOCKERD_TGZ_URL"; exit 1; }
tar -xzf /tmp/cri-dockerd.tgz -C /tmp
cp /tmp/cri-dockerd/cri-dockerd /usr/bin/
rm -rf /tmp/cri-dockerd /tmp/cri-dockerd.tgz

cat > /etc/systemd/system/cri-docker.service <<'EOF'
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target firewalld.service docker.service
Wants=network-online.target
Requires=cri-docker.socket

[Service]
Type=notify
ExecStart=/usr/bin/cri-dockerd --container-runtime-endpoint fd://
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/cri-docker.socket <<'EOF'
[Unit]
Description=CRI Docker Socket for the API
PartOf=cri-docker.service

[Socket]
ListenStream=%t/cri-dockerd.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

cat > /etc/systemd/system/containerd.service <<'EOF'
[Unit]
Description=containerd container runtime
After=network.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/docker.service <<'EOF'
[Unit]
Description=Docker Application Container Engine
After=network-online.target containerd.service
Wants=network-online.target
Requires=containerd.service

[Service]
Type=notify
ExecStart=/usr/bin/dockerd -H unix:///var/run/docker.sock --containerd=/run/containerd/containerd.sock
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
RestartSec=2
Restart=always
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

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

if [ -f /etc/sysconfig/docker ]; then
  sed -i "s/--default-ulimit nofile=1024:4096/--default-ulimit nofile=65535:65535/g" /etc/sysconfig/docker
fi

# crictl (cp-node-reporter, kubeadm image pulls) talks CRI to cri-dockerd, not containerd directly.
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/cri-dockerd.sock
image-endpoint: unix:///run/cri-dockerd.sock
EOF

# Enable forwarding and make sure iptables are used
# See https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl
modprobe br_netfilter
cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/k8s.conf

# Disable SELinux as required by the Kube
# See https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/#installing-kubeadm-kubelet-and-kubectl
# Ignore exit code as setenforce will return 1 if selinux is already disabled
# which will faile the whole script as -e is set
setenforce 0 || true
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

cd /tmp || exit 42
curl -O https://get.helm.sh/helm-v3.3.4-linux-amd64.tar.gz
tar -xzf helm-v3.3.4-linux-amd64.tar.gz --strip-components=1 linux-amd64/helm
mv helm /usr/local/bin

curl -LO https://github.com/helmfile/helmfile/releases/download/v1.4.1/helmfile_1.4.1_linux_amd64.tar.gz
tar -xzf helmfile_1.4.1_linux_amd64.tar.gz helmfile 
chmod 777 helmfile
mv helmfile /usr/local/bin

mkdir -p /root/.local/share/helm/plugins
mkdir -p "${CLOUD_PIPELINE_DISTRO_DIR}"
mkdir -p "${CLOUD_PIPELINE_DISTRO_DIR}/k8s-bootstrap"

curl -L https://github.com/databus23/helm-diff/releases/download/v3.4.2/helm-diff-linux-amd64.tgz | tar -C /root/.local/share/helm/plugins -xzv

reboot

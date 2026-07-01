#!/bin/bash

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
cat <<EOT > /etc/docker/daemon.json
{
  $DOCKER_DATA_ROOT_ENTRY
  "exec-opts": ["native.cgroupdriver=systemd"],
  "storage-driver": "overlay2"
}
EOT

if [ -f /etc/sysconfig/docker ]; then
  sed -i "s/--default-ulimit nofile=1024:4096/--default-ulimit nofile=65535:65535/g" /etc/sysconfig/docker
fi

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
mkdir -p /var/lib/cloud-pipeline/deploy
mkdir -p /var/lib/cloud-pipeline/deploy/k8s-bootstrap

curl -L https://github.com/databus23/helm-diff/releases/download/v3.4.2/helm-diff-linux-amd64.tgz | tar -C /root/.local/share/helm/plugins -xzv

grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0 systemd.legacy_systemd_cgroup_controller=1"

reboot

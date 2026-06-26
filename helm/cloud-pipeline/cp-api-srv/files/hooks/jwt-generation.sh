#!/bin/bash
set -e

# Install kubectl
# This overwrites any existing configuration in /etc/yum.repos.d/kubernetes.repo
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.35/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.35/rpm/repodata/repomd.xml.key
EOF

yum install -y kubectl

echo "Generating JWT token"
CP_DEFAULT_ADMIN_NAME="${CP_DEFAULT_ADMIN_NAME:-pipe_admin}"
CP_API_JWT_ADMIN=$(java -jar /opt/api/jwt-generator.jar --private /opt/api/pki/jwt.key.private --expires 94608000 --claim user_id=1 --claim user_name=$CP_DEFAULT_ADMIN_NAME --claim role=ROLE_ADMIN --claim group=ADMIN 2>/dev/null | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

echo "Adding JWT token to ${CP_API_TOKEN_SECRET_NAME} secret..."
ESCAPED_JWT=$(printf '%s' "$CP_API_JWT_ADMIN" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
kubectl patch secret "${CP_API_TOKEN_SECRET_NAME}" \
  -n "${NAMESPACE}" \
  --type merge \
  -p "{\"stringData\": {\"CP_API_JWT_ADMIN\": \"$ESCAPED_JWT\"}}"

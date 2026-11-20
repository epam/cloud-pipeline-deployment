#!/bin/bash
cat >> /var/lib/cloud-pipeline/deploy/k8s-bootstrap/bootstrap.env <<'EOF'
ROLE=application-node
CP_STORAGE_TYPE=${storage_type}
%{ if storage_type == "efs" ~}
CP_STORAGE_ID=${storage_id}
%{ else ~}
CP_STORAGE_LUSTRE_DNS=${storage_dns_name}
CP_STORAGE_LUSTRE_MOUNT=${storage_mount_name}
%{ endif ~}
CP_APPLICATION_NODE_LABELS=${application_node_labels}
EOF

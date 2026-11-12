#!/bin/bash
cat >> /var/lib/cloud-pipeline/deploy/k8s-bootstrap/bootstrap.env <<'EOF'
CP_STORAGE_TYPE=${storage_type}
%{ if storage_type == "efs" ~}
CP_STORAGE_ID=${storage_id}
%{ else ~}
CP_STORAGE_LUSTRE_DNS=${storage_dns_name}
CP_STORAGE_LUSTRE_MOUNT=${storage_mount_name}
%{ endif ~}
APPLICATION_NODE_COUNT=${application_node_count}
%{ if master_node_labels != "" ~}
CP_MASTER_NODE_LABELS=${master_node_labels}
%{ endif ~}
EOF

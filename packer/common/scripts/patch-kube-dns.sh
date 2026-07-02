#!/usr/bin/env bash

# Usage:
#   patch-kube-dns.sh [OPTIONS]
#
# Options:
#   --node-selector-label <key>=<value>   Node selector label for kube-dns pod scheduling.
#                                         Default: node-role.kubernetes.io/master=
#   --dns-hosts-sync-image-version <ver>  Cloud Pipeline build version for the dns-hosts-sync image.
#                                         Default: 0.17
#
# Examples:
#   patch-kube-dns.sh
#   patch-kube-dns.sh --node-selector-label node-role.kubernetes.io/master=
#   patch-kube-dns.sh --node-selector-label node-role.kubernetes.io/master=true
#   patch-kube-dns.sh --node-selector-label=kubernetes.io/hostname=my-node
#   patch-kube-dns.sh --node-selector-label kubernetes.io/hostname=my-node
#   patch-kube-dns.sh --dns-hosts-sync-image-version 0.17

_parse_args() {
  _KUBE_DNS_NODE_SELECTOR_LABEL="node-role.kubernetes.io/master="
  _DNS_HOSTS_SYNC_IMAGE_VERSION="0.17"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node-selector-label=*)          _KUBE_DNS_NODE_SELECTOR_LABEL="${1#*=}" ;;
      --node-selector-label)            _KUBE_DNS_NODE_SELECTOR_LABEL="$2"; shift ;;
      --dns-hosts-sync-image-version=*) _DNS_HOSTS_SYNC_IMAGE_VERSION="${1#*=}" ;;
      --dns-hosts-sync-image-version)   _DNS_HOSTS_SYNC_IMAGE_VERSION="$2"; shift ;;
      *) echo "WARNING: unknown argument '$1', ignoring" >&2 ;;
    esac
    shift
  done
  _KUBE_DNS_NODE_SELECTOR_KEY="${_KUBE_DNS_NODE_SELECTOR_LABEL%%=*}"
  _KUBE_DNS_NODE_SELECTOR_VALUE="${_KUBE_DNS_NODE_SELECTOR_LABEL#*=}"
  _DNS_HOSTS_SYNC_IMAGE="quay.io/lifescience/cloud-pipeline:dns-hosts-sync-${_DNS_HOSTS_SYNC_IMAGE_VERSION}"
}

_parse_args "$@"

kubectl create clusterrolebinding kube-dns-viewer-binding \
                                            --clusterrole view \
                                            --user system:serviceaccount:kube-system:kube-dns

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cp-dnsmasq-hosts
  namespace: kube-system
data:
  hosts: ""
EOF

kubectl patch deployment kube-dns \
            --namespace kube-system \
            --type='json' \
            -p="[
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/nodeSelector\",
                        \"value\": {
                            \"${_KUBE_DNS_NODE_SELECTOR_KEY}\": \"${_KUBE_DNS_NODE_SELECTOR_VALUE}\"
                        }
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/shareProcessNamespace\",
                        \"value\": true
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/volumes/-\",
                        \"value\": {
                            \"configMap\": {
                                \"name\": \"cp-dnsmasq-hosts\",
                                \"optional\": true
                            },
                            \"name\": \"cp-dnsmasq-hosts\"
                        }
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/volumes/-\",
                        \"value\": {
                            \"emptyDir\": {},
                            \"name\": \"cp-dnsmasq-pods\"
                        }
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/containers/1/volumeMounts/-\",
                        \"value\": {
                            \"mountPath\": \"/etc/hosts.d/hosts\",
                            \"name\": \"cp-dnsmasq-hosts\"
                        }
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/containers/1/volumeMounts/-\",
                        \"value\": {
                            \"mountPath\": \"/etc/hosts.d/pods\",
                            \"name\": \"cp-dnsmasq-pods\"
                        }
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/containers/1/args/-\",
                        \"value\": \"--dns-forward-max=5000\"
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/containers/1/args/-\",
                        \"value\": \"--hostsdir=/etc/hosts.d/hosts\"
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/containers/1/args/-\",
                        \"value\": \"--hostsdir=/etc/hosts.d/pods\"
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/containers/1/args/-\",
                        \"value\": \"--bind-interfaces\"
                    },
                    {
                        \"op\": \"replace\",
                        \"path\": \"/spec/template/spec/containers/2/image\",
                        \"value\": \"gcr.io/google-containers/k8s-dns-sidecar:1.15.11\"
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/containers/-\",
                        \"value\": {
                            \"command\": [
                                \"python\",
                                \"/sync-hosts.py\"
                            ],
                            \"image\": \"${_DNS_HOSTS_SYNC_IMAGE}\",
                            \"imagePullPolicy\": \"IfNotPresent\",
                            \"name\": \"pods\",
                            \"volumeMounts\": [
                                {
                                    \"mountPath\": \"/etc/hosts.d/pods\",
                                    \"name\": \"cp-dnsmasq-pods\"
                                }
                            ]
                        }
                    }
                ]"
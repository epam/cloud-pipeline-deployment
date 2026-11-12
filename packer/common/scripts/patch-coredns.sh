#!/usr/bin/env bash

# Usage:
#   patch-coredns.sh [OPTIONS]
#
# Options:
#   --node-selector-label <key>=<value>   Node selector label for coredns pod scheduling.
#                                         Default: node-role.kubernetes.io/master=
#   --dns-hosts-sync-image-version <ver>  Cloud Pipeline build version for the dns-hosts-sync image.
#                                         Default: 0.17
#
# Examples:
#   patch-coredns.sh
#   patch-coredns.sh --node-selector-label node-role.kubernetes.io/master=
#   patch-coredns.sh --node-selector-label node-role.kubernetes.io/master=true
#   patch-coredns.sh --node-selector-label=kubernetes.io/hostname=my-node
#   patch-coredns.sh --node-selector-label kubernetes.io/hostname=my-node
#   patch-coredns.sh --dns-hosts-sync-image-version 0.17

set -e

_parse_args() {
  _COREDNS_NODE_SELECTOR_LABEL="node-role.kubernetes.io/master="
  _DNS_HOSTS_SYNC_IMAGE_VERSION="0.17"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node-selector-label=*)          _COREDNS_NODE_SELECTOR_LABEL="${1#*=}" ;;
      --node-selector-label)            _COREDNS_NODE_SELECTOR_LABEL="$2"; shift ;;
      --dns-hosts-sync-image-version=*) _DNS_HOSTS_SYNC_IMAGE_VERSION="${1#*=}" ;;
      --dns-hosts-sync-image-version)   _DNS_HOSTS_SYNC_IMAGE_VERSION="$2"; shift ;;
      *) echo "WARNING: unknown argument '$1', ignoring" >&2 ;;
    esac
    shift
  done
  _COREDNS_NODE_SELECTOR_KEY="${_COREDNS_NODE_SELECTOR_LABEL%%=*}"
  _COREDNS_NODE_SELECTOR_VALUE="${_COREDNS_NODE_SELECTOR_LABEL#*=}"
  _DNS_HOSTS_SYNC_IMAGE="quay.io/lifescience/cloud-pipeline:dns-hosts-sync-${_DNS_HOSTS_SYNC_IMAGE_VERSION}"
}

_parse_args "$@"

# coredns's ServiceAccount needs to read Pod objects for the dns-hosts-sync sidecar
# (mirrors the "view" binding previously granted to the kube-dns ServiceAccount).
kubectl create clusterrolebinding coredns-viewer-binding \
                                            --clusterrole view \
                                            --user system:serviceaccount:kube-system:coredns

# Static hosts entries, patched in by Helm hooks across the charts (cp-edge, cp-docker-registry,
# cp-git, etc. — see lib.patchDNSScript / lib.patchDNSStaticScript). Name/key kept identical to the
# kube-dns era so none of those hooks need to change.
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cp-dnsmasq-hosts
  namespace: kube-system
data:
  hosts: ""
EOF

# Pin coredns to the requested node(s), same as kube-dns previously.
kubectl patch deployment coredns \
            --namespace kube-system \
            --type=merge \
            -p="{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"${_COREDNS_NODE_SELECTOR_KEY}\":\"${_COREDNS_NODE_SELECTOR_VALUE}\"}}}}}"

# Wire up:
#  - a "custom-hosts" emptyDir, merged every 5s from the static cp-dnsmasq-hosts ConfigMap and the
#    dynamic per-pod hosts written by the "pods" sidecar, and read by CoreDNS's hosts plugin
#    (which only accepts a single file, unlike dnsmasq's --hostsdir, hence the merge step).
#  - the "pods" sidecar (unchanged dns-hosts-sync image/entrypoint) writing dynamic entries.
kubectl patch deployment coredns \
            --namespace kube-system \
            --type='json' \
            -p="[
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
                        \"path\": \"/spec/template/spec/volumes/-\",
                        \"value\": {
                            \"emptyDir\": {},
                            \"name\": \"cp-coredns-custom-hosts\"
                        }
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/containers/0/volumeMounts/-\",
                        \"value\": {
                            \"mountPath\": \"/etc/coredns/custom-hosts\",
                            \"name\": \"cp-coredns-custom-hosts\",
                            \"readOnly\": true
                        }
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
                    },
                    {
                        \"op\": \"add\",
                        \"path\": \"/spec/template/spec/containers/-\",
                        \"value\": {
                            \"command\": [
                                \"sh\",
                                \"-c\",
                                \"while true; do cat /etc/hosts.d/static/hosts /etc/hosts.d/pods/pods 2>/dev/null > /etc/coredns/custom-hosts/hosts.new; mv /etc/coredns/custom-hosts/hosts.new /etc/coredns/custom-hosts/hosts; sleep 5; done\"
                            ],
                            \"image\": \"busybox:1.36\",
                            \"imagePullPolicy\": \"IfNotPresent\",
                            \"name\": \"hosts-merger\",
                            \"volumeMounts\": [
                                {
                                    \"mountPath\": \"/etc/hosts.d/static\",
                                    \"name\": \"cp-dnsmasq-hosts\",
                                    \"readOnly\": true
                                },
                                {
                                    \"mountPath\": \"/etc/hosts.d/pods\",
                                    \"name\": \"cp-dnsmasq-pods\",
                                    \"readOnly\": true
                                },
                                {
                                    \"mountPath\": \"/etc/coredns/custom-hosts\",
                                    \"name\": \"cp-coredns-custom-hosts\"
                                }
                            ]
                        }
                    }
                ]"

# Add a "hosts" block to the Corefile so names from the merged file above resolve, falling
# through to the normal kubernetes/forward chain for everything else. Plugin execution order in
# CoreDNS is fixed internally (by plugin.cfg), so where this line sits in the file doesn't matter.
_COREFILE=$(kubectl get configmap coredns --namespace kube-system -o jsonpath='{.data.Corefile}')
if ! grep -q 'hosts /etc/coredns/custom-hosts/hosts' <<< "$_COREFILE"; then
  _PATCHED_COREFILE=$(awk '
    /{/ && !done { print; print "    hosts /etc/coredns/custom-hosts/hosts {"; print "        fallthrough"; print "    }"; done=1; next }
    { print }
  ' <<< "$_COREFILE")
  kubectl create configmap coredns --namespace kube-system \
              --from-literal=Corefile="$_PATCHED_COREFILE" \
              --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart deployment coredns --namespace kube-system
fi

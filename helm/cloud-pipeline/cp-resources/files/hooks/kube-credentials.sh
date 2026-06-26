#!/bin/bash
set -euo pipefail
# cluster-admin for namespace default SA + kube-dns view: Helm hook ClusterRoleBindings (weight -55), not kubectl here.

CA_CRT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
CP_KUBE_KUBEADM_CERT_HASH="$(
  openssl x509 -in "$CA_CRT" -noout -pubkey \
    | openssl rsa -pubin -outform DER 2>/dev/null \
    | sha256sum | awk '{print $1}'
)"
if [ -z "$CP_KUBE_KUBEADM_CERT_HASH" ]; then
  echo "Failed to compute CP_KUBE_KUBEADM_CERT_HASH from service account CA" >&2
  exit 1
fi

KUBE_TOKENS_JSON=$(kubectl get secrets -n "$KUBE_SYSTEM_NS" \
  --field-selector type=bootstrap.kubernetes.io/token -o json)
KUBE_TOKEN_NAME=$(echo "$KUBE_TOKENS_JSON" | jq -r '[.items[] | select((.data["expiration"] // "") == "")] | .[0].metadata.name // empty')
if [ -z "$KUBE_TOKEN_NAME" ] || [ "$KUBE_TOKEN_NAME" = "null" ]; then
  echo "No bootstrap.kubernetes.io/token secret in $KUBE_SYSTEM_NS; create one (e.g. kubeadm token create)" >&2
  exit 1
fi
TOKEN_ID=$(kubectl get secret "$KUBE_TOKEN_NAME" -n "$KUBE_SYSTEM_NS" -o json \
  | jq -r '.data["token-id"] // empty' | base64 -d)
TOKEN_SECRET=$(kubectl get secret "$KUBE_TOKEN_NAME" -n "$KUBE_SYSTEM_NS" -o json \
  | jq -r '.data["token-secret"] // empty' | base64 -d)
CP_KUBE_KUBEADM_TOKEN="${TOKEN_ID}.${TOKEN_SECRET}"
if [ -z "$CP_KUBE_KUBEADM_TOKEN" ] || [ "$CP_KUBE_KUBEADM_TOKEN" = "." ]; then
  echo "Could not build kubeadm bootstrap token from secret $KUBE_TOKEN_NAME" >&2
  exit 1
fi

# Never parse "kubectl describe sa" (fragile; wrong pipeline → binary garbage in cp-config-global).
CP_KUBE_NODE_TOKEN=""
SA_JSON=$(kubectl get sa "$CANAL_SA" -n "$KUBE_SYSTEM_NS" -o json 2>/dev/null || echo '{}')
while IFS= read -r sec; do
  [ -z "$sec" ] && continue
  stype=$(kubectl get secret "$sec" -n "$KUBE_SYSTEM_NS" -o jsonpath='{.type}' 2>/dev/null || true)
  [ "$stype" = "kubernetes.io/service-account-token" ] || continue
  b64=$(kubectl get secret "$sec" -n "$KUBE_SYSTEM_NS" -o jsonpath='{.data.token}' 2>/dev/null || true)
  [ -n "$b64" ] || continue
  dec=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
  [ -n "$dec" ] || continue
  if printf '%s' "$dec" | LC_ALL=C grep -q '[^[:print:]]'; then
    continue
  fi
  CP_KUBE_NODE_TOKEN="$dec"
  break
done < <(echo "$SA_JSON" | jq -r '.secrets[]?.name // empty')

if [ -z "$CP_KUBE_NODE_TOKEN" ]; then
  CP_KUBE_NODE_TOKEN=$(kubectl create token "$CANAL_SA" -n "$KUBE_SYSTEM_NS" --duration=8760h 2>/dev/null || true)
fi
if [ -z "$CP_KUBE_NODE_TOKEN" ] || printf '%s' "$CP_KUBE_NODE_TOKEN" | LC_ALL=C grep -q '[^[:print:]]'; then
  echo "Could not read a valid printable token for $KUBE_SYSTEM_NS/$CANAL_SA (check SA secrets or token create RBAC)" >&2
  exit 1
fi

echo "Merging CP_KUBE_KUBEADM_*, CP_KUBE_NODE_TOKEN into cp-config-global in namespace $NAMESPACE"
for _key in CP_KUBE_KUBEADM_TOKEN CP_KUBE_KUBEADM_CERT_HASH CP_KUBE_NODE_TOKEN; do
  _value="${!_key}"
  _current=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json | jq -r --arg k "$_key" '.data // {} | .[$k] // "__MISSING__"')

  if [ "$_current" = "$_value" ]; then
    echo "cp-config-global.data['$_key'] unchanged; skipping."
    continue
  fi

  _patch=$(jq -n --arg k "$_key" --arg v "$_value" '{data:{($k):$v}}')
  kubectl patch configmap cp-config-global -n "$NAMESPACE" --type merge -p "$_patch" >/dev/null
  if [ "$_current" = "__MISSING__" ]; then
    echo "Added cp-config-global.data['$_key']."
  else
    echo "Updated cp-config-global.data['$_key']."
  fi
done

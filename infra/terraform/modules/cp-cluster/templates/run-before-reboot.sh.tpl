#!/bin/bash
set -u

NODE_NAME="$(hostname)"

mkdir -p "/opt/system/logs/$NODE_NAME"
exec > >(tee -a "/opt/system/logs/$NODE_NAME/reboot.log") 2>&1
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) run-before-reboot starting ==="

KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export KUBECONFIG

if [ ! -f "$KUBECONFIG" ]; then
  echo "No kubeconfig at $KUBECONFIG yet -- nothing to stop."
else
  # Find pods matching the cp-api-db label or name on this node
  _db_pods=$(kubectl get pods --all-namespaces \
    --field-selector spec.nodeName="$NODE_NAME" \
    -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.labels | to_entries[]? | select(.key | test("^cloud-pipeline/.*-db$")) | .value == "true") | "\(.metadata.namespace) \(.metadata.name)"' \
    | sort -u)

  if [ -z "$_db_pods" ]; then
    echo "No database pods on this node -- nothing to stop."
  else
    echo "$_db_pods" | while read -r _namespace _pod; do
      [ -z "$_pod" ] && continue
      echo "Stopping database inside pod ${_namespace}/${_pod} before reboot..."
      
      kubectl exec -n "$_namespace" "$_pod" -- bash -c \
        "su - postgres -c 'pg_ctl stop -D /var/lib/postgresql/data -m smart' || pg_ctlcluster 15 main stop || systemctl stop postgresql" \
        || echo "WARNING: failed to gracefully stop database in ${_namespace}/${_pod}, proceeding..." >&2
    done
    echo "Database shutdown complete."
  fi
fi

# Add further pre-reboot steps below.

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) run-before-reboot finished ==="
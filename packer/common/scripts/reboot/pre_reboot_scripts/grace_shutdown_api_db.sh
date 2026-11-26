#!/bin/bash
# If this node is labeled to host cp-api-db (the internal Cloud Pipeline API database), finds the
# matching pod scheduled on this node and gracefully stops Postgres inside it before reboot.
set -u

DB_LABEL="cloud-pipeline/cp-api-db"
DB_NAME="cp-api-db"
NODE_NAME="$(hostname)"

KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export KUBECONFIG

if [ ! -f "$KUBECONFIG" ]; then
  echo "No kubeconfig at $KUBECONFIG yet -- skipping ${DB_NAME} shutdown check."
  exit 0
fi

_node_label_value=$(kubectl get node "$NODE_NAME" -o jsonpath="{.metadata.labels['${DB_LABEL}']}" 2>/dev/null) \
  || { echo "WARNING: failed to read labels for node ${NODE_NAME}, skipping ${DB_NAME} shutdown check." >&2; exit 0; }

if [ "$_node_label_value" != "true" ]; then
  echo "Node ${NODE_NAME} is not labeled ${DB_LABEL}=true -- nothing to stop here."
  exit 0
fi

echo "Node ${NODE_NAME} is labeled ${DB_LABEL}=true -- looking for the ${DB_NAME} pod on this node."

_db_pods=$(kubectl get pods --all-namespaces \
  --field-selector spec.nodeName="$NODE_NAME" \
  -l "${DB_LABEL}=true" \
  -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | sort -u)

if [ -z "$_db_pods" ]; then
  echo "WARNING: node is labeled ${DB_LABEL}=true but no matching ${DB_NAME} pod was found on this node." >&2
  exit 0
fi

echo "$_db_pods" | while read -r _namespace _pod; do
  [ -z "$_pod" ] && continue
  echo "Stopping database inside pod ${_namespace}/${_pod} before reboot..."
  if kubectl exec -n "$_namespace" "$_pod" -- bash -c \
    "su - postgres -c 'pg_ctl stop -D /var/lib/postgresql/data -m smart' || pg_ctlcluster 15 main stop || systemctl stop postgresql"; then
    echo "${_namespace}/${_pod}: database stopped gracefully."
  else
    echo "WARNING: failed to gracefully stop database in ${_namespace}/${_pod}, proceeding anyway." >&2
  fi
done
echo "${DB_NAME} shutdown check complete."

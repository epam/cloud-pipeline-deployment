#!/bin/bash
# Runs on every node (master and application) before every reboot -- installed by a systemd
# unit ordered Before=reboot.target, so the actual reboot waits for this script to finish.
# Add further pre-reboot steps below as needed.
set -u

NODE_NAME="$(hostname)"

# /opt is the shared EFS mount, not node-local -- log into the same per-node subfolder
# cp-api-srv's own logs use under it (see cloud-pipeline's deploy/docker/cp-api-srv/init-api:
# API_LOG_HOME="/var/log/cp-api/$${CP_API_SRV_INSTANCE_NAME:-$CP_API_CURRENT_NODE_NAME}", mapped
# via hostPath to /opt/api/logs/<node-name> on the host). A flat /opt/api/logs/reboot.log would
# be the exact same file on every node, and entries from different nodes would collide.
mkdir -p "/opt/api/logs/$NODE_NAME"
exec > >(tee -a "/opt/api/logs/$NODE_NAME/reboot.log") 2>&1
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) run-before-reboot starting ==="

# Gracefully stop any Cloud Pipeline database pod scheduled on this node -- identified by the
# cloud-pipeline/<name>-db=true label convention (cp-api-db, cp-gitlab-db, and any future chart
# following the same convention) -- so Postgres gets a clean shutdown instead of being killed
# mid-write.
KUBECONFIG="$${KUBECONFIG:-/root/.kube/config}"
export KUBECONFIG

if [ ! -f "$KUBECONFIG" ]; then
  echo "No kubeconfig at $KUBECONFIG yet -- nothing to stop."
else
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
      echo "Gracefully stopping database pod $${_namespace}/$${_pod} before reboot..."
      kubectl delete pod "$_pod" -n "$_namespace" --grace-period=${db_stop_grace_period_seconds} --wait=true \
        || echo "WARNING: failed to gracefully delete $${_namespace}/$${_pod}, proceeding with reboot anyway" >&2
    done
    echo "Database shutdown complete."
  fi
fi

# Add further pre-reboot steps below.

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) run-before-reboot finished ==="

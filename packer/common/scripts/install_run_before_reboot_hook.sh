#!/bin/bash
# Bakes in the baseline cp-run-before-reboot hook (script + systemd unit) so it's present and
# enabled from the very first boot, before terraform/SSM ever gets a chance to run. Terraform's
# run-before-reboot-sync.tf later overwrites both files on already-running instances whenever
# infra/terraform/modules/cp-cluster/templates/run-before-reboot.sh.tpl or
# cp-run-before-reboot.service change -- no AMI rebuild needed for those updates, only for this
# initial baseline.
set -e

cat > /usr/local/bin/cp-run-before-reboot.sh <<'SCRIPTEOF'
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
SCRIPTEOF
chmod +x /usr/local/bin/cp-run-before-reboot.sh

cat > /etc/systemd/system/cp-run-before-reboot.service <<'UNITEOF'
[Unit]
Description=Run Cloud Pipeline pre-reboot hooks on this node
DefaultDependencies=no
After=remote-fs.target network-online.target
Before=reboot.target shutdown.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cp-run-before-reboot.sh
TimeoutStartSec=120

[Install]
WantedBy=reboot.target shutdown.target halt.target
UNITEOF

systemctl daemon-reload
systemctl enable cp-run-before-reboot.service

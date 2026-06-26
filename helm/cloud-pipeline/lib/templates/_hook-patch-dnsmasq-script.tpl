{{/*
Shell script body for the dnsmasq-hosts patch hook.
Defined as a named template because lib chart .Files cannot be referenced from calling charts.
Usage: {{ include "lib.patchDNSScript" . }}
*/}}
{{- define "lib.patchDNSScript" -}}
set -e

if ! error=$(kubectl get cm cp-dnsmasq-hosts -n kube-system 2>&1); then
  echo "ERROR: ConfigMap cp-dnsmasq-hosts does not exist in kube-system namespace."
  echo "$error"
  exit 1
fi

ip=$(kubectl get svc -n "$NAMESPACE" "$SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -z "$ip" ]; then
  echo "Skipping $HOST ($SVC not found in $NAMESPACE)"
  exit 0
fi
echo "Resolved $SVC -> $ip"

# Optimistic concurrency: read full CM JSON (with resourceVersion), compute new hosts value,
# kubectl replace (sends resourceVersion so Kubernetes rejects with 409 if another writer
# changed the object since our read). Retry on conflict so concurrent hook Jobs from different
# releases do not overwrite each other's entries.
_max_retries=15
_retry=0
new_entry="$ip $HOST"
while true; do
  _cm_json=$(kubectl get cm cp-dnsmasq-hosts -n kube-system -o json)
  existing=$(printf '%s' "$_cm_json" | jq -r '.data.hosts // ""')

  if printf '%s\n' "$existing" | awk -v ip="$ip" -v host="$HOST" '
    BEGIN { found = 0 }
    NF >= 2 && $1 == ip {
      for (i = 2; i <= NF; i++) {
        if ($i == host) { found = 1; exit }
      }
    }
    END { exit(found ? 0 : 1) }
  '; then
    echo "cp-dnsmasq-hosts already has $ip $HOST; skipping ConfigMap patch."
    break
  fi

  filtered=""
  if [ -n "$existing" ]; then
    filtered=$(printf '%s\n' "$existing" | awk -v host="$HOST" '
      NF == 0 { next }
      {
        for (i = 2; i <= NF; i++) if ($i == host) next
        print
      }
    ')
  fi
  if [ -z "$filtered" ]; then
    updated="$new_entry"
  else
    updated="${filtered}"$'\n'"${new_entry}"
  fi
  updated=$(printf '%s\n' "$updated" | sed '/^$/d')

  echo "Set cp-dnsmasq-hosts entry for $HOST -> $ip (replacing prior lines for this name)"

  _updated_cm=$(printf '%s' "$_cm_json" | jq --arg v "$updated" '.data.hosts = $v')
  if printf '%s' "$_updated_cm" | kubectl replace -f - 2>/tmp/_dns_patch_err; then
    echo "Patched cp-dnsmasq-hosts: $new_entry"
    break
  fi

  if grep -qiE "conflict|409" /tmp/_dns_patch_err; then
    _retry=$(( _retry + 1 ))
    if [ "$_retry" -ge "$_max_retries" ]; then
      echo "ERROR: cp-dnsmasq-hosts patch failed after $_max_retries retries (conflict)."
      cat /tmp/_dns_patch_err >&2
      exit 1
    fi
    sleep $(( (RANDOM % 3) + 1 ))
    echo "Conflict updating cp-dnsmasq-hosts (retry $_retry/$_max_retries); re-reading..."
    continue
  fi

  cat /tmp/_dns_patch_err >&2
  exit 1
done

echo "Restarting kube-dns in kube-system so dnsmasq remounts cp-dnsmasq-hosts (not deferred to cp-edge postsync)..."
if kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q .; then
  kubectl delete pods -n kube-system -l k8s-app=kube-dns --ignore-not-found --wait=false
  if kubectl rollout status deployment/kube-dns -n kube-system --timeout=120s 2>/dev/null; then
    echo "kube-dns deployment reported ready"
  else
    echo "NOTE: rollout status for deployment/kube-dns unavailable or failed (RBAC/name); waiting for replacement kube-dns pod..."
    sleep 45
  fi
else
  echo "No pods with label k8s-app=kube-dns in kube-system; skipping kube-dns restart."
fi
echo "Waiting 15s for DNS to stabilize..."
sleep 15
{{- end -}}

{{/*
Shell script body for the static-entries dnsmasq-hosts patch hook.
Patches cp-dnsmasq-hosts with IP/host pairs known at Helm render time (no k8s service lookup).
Calls are rendered inline per entry; a single kube-dns restart follows all patches.
Usage: {{ include "lib.patchDNSStaticScript" . }}
*/}}
{{- define "lib.patchDNSStaticScript" -}}
set -e

if ! error=$(kubectl get cm cp-dnsmasq-hosts -n kube-system 2>&1); then
  echo "ERROR: ConfigMap cp-dnsmasq-hosts does not exist in kube-system namespace."
  echo "$error"
  exit 1
fi

patch_one_entry() {
  local ip="$1" host="$2" new_entry="$1 $2"
  local _retry=0 _max_retries=15
  while true; do
    local _cm_json
    _cm_json=$(kubectl get cm cp-dnsmasq-hosts -n kube-system -o json)
    local existing
    existing=$(printf '%s' "$_cm_json" | jq -r '.data.hosts // ""')

    if printf '%s\n' "$existing" | awk -v ip="$ip" -v host="$host" '
      BEGIN { found = 0 }
      NF >= 2 && $1 == ip {
        for (i = 2; i <= NF; i++) {
          if ($i == host) { found = 1; exit }
        }
      }
      END { exit(found ? 0 : 1) }
    '; then
      echo "cp-dnsmasq-hosts already has $ip $host; skipping."
      return
    fi

    local filtered=""
    if [ -n "$existing" ]; then
      filtered=$(printf '%s\n' "$existing" | awk -v host="$host" '
        NF == 0 { next }
        {
          for (i = 2; i <= NF; i++) if ($i == host) next
          print
        }
      ')
    fi
    local updated
    if [ -z "$filtered" ]; then
      updated="$new_entry"
    else
      updated="${filtered}"$'\n'"${new_entry}"
    fi
    updated=$(printf '%s\n' "$updated" | sed '/^$/d')

    echo "Set cp-dnsmasq-hosts entry for $host -> $ip (replacing prior lines for this name)"

    local _updated_cm
    _updated_cm=$(printf '%s' "$_cm_json" | jq --arg v "$updated" '.data.hosts = $v')
    if printf '%s' "$_updated_cm" | kubectl replace -f - 2>/tmp/_dns_patch_err; then
      echo "Patched cp-dnsmasq-hosts: $new_entry"
      return
    fi

    if grep -qiE "conflict|409" /tmp/_dns_patch_err; then
      _retry=$(( _retry + 1 ))
      if [ "$_retry" -ge "$_max_retries" ]; then
        echo "ERROR: cp-dnsmasq-hosts patch for $host failed after $_max_retries retries (conflict)."
        cat /tmp/_dns_patch_err >&2
        exit 1
      fi
      sleep $(( (RANDOM % 3) + 1 ))
      echo "Conflict updating cp-dnsmasq-hosts for $host (retry $_retry/$_max_retries); re-reading..."
      continue
    fi

    cat /tmp/_dns_patch_err >&2
    exit 1
  done
}

{{ range .Values.customDNS.entries -}}
patch_one_entry {{ .ip | quote }} {{ .host | quote }}
{{ end -}}

echo "Restarting kube-dns in kube-system so dnsmasq remounts cp-dnsmasq-hosts..."
if kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q .; then
  kubectl delete pods -n kube-system -l k8s-app=kube-dns --ignore-not-found --wait=false
  if kubectl rollout status deployment/kube-dns -n kube-system --timeout=120s 2>/dev/null; then
    echo "kube-dns deployment reported ready"
  else
    echo "NOTE: rollout status for deployment/kube-dns unavailable or failed (RBAC/name); waiting for replacement kube-dns pod..."
    sleep 45
  fi
else
  echo "No pods with label k8s-app=kube-dns in kube-system; skipping kube-dns restart."
fi
echo "Waiting 15s for DNS to stabilize..."
sleep 15
{{- end -}}

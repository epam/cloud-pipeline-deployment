{{/*
Shell script body for the cp-config-global patch hook.
Defined as a named template because lib chart .Files cannot be referenced from calling charts.
Usage: {{ include "lib.cpConfigGlobal.patchScript" (dict "context" . "prePatchAdditionalScript" "" "serviceName" "my-service") }}
*/}}
{{- define "lib.cpConfigGlobal.patchScript" -}}
{{- $serviceName := index . "serviceName" | default "" -}}
{{- $prePatchAdditionalScript := index . "prePatchAdditionalScript" | default "" | toString -}}
set -euo pipefail

{{- if $prePatchAdditionalScript }}
{{ $prePatchAdditionalScript | nindent 0 }}
{{- end }}

# ConfigMap volume keys are usually symlinks to ..data/; find -type f misses them.
shopt -s nullglob
_patch_paths=(/etc/cp-config-global-patch/*)
shopt -u nullglob
if [ "${#_patch_paths[@]}" -eq 0 ]; then
  echo "WARNING: no keys found in configmap-to-update-{{ $serviceName }}; nothing to patch."
  exit 0
fi
mapfile -t patch_files < <(printf '%s\n' "${_patch_paths[@]}" | LC_ALL=C sort -u)

# Optimistic concurrency: read-compute-replace with retry on 409 Conflict so that
# concurrent hook Jobs from different releases do not overwrite each other's keys.
_max_retries=15
_retry=0
while true; do
  _cm_json=$(kubectl get configmap cp-config-global -n "$NAMESPACE" -o json)
  _updated_cm="$_cm_json"
  _needs_patch=false

  for f in "${patch_files[@]}"; do
    key=$(basename "$f")
    [[ "$key" == ..* ]] && continue
    value=$(cat "$f")
    current=$(printf '%s' "$_cm_json" | jq -r --arg k "$key" '.data // {} | .[$k] // "__MISSING__"')

    if [ "$current" = "$value" ]; then
      echo "cp-config-global.data['$key'] unchanged; skipping."
      continue
    fi

    _needs_patch=true
    _updated_cm=$(printf '%s' "$_updated_cm" | jq --arg k "$key" --arg v "$value" '.data[$k] = $v')

    if [ "$current" = "__MISSING__" ]; then
      echo "Will add cp-config-global.data['$key']."
    else
      echo "Will update cp-config-global.data['$key']."
    fi
  done

  if [ "$_needs_patch" = "false" ]; then
    echo "All keys up to date; nothing to replace."
    break
  fi

  if printf '%s' "$_updated_cm" | kubectl replace -f - 2>/tmp/_cm_patch_err; then
    echo "cp-config-global patch hook finished for configmap-to-update-{{ $serviceName }}."
    break
  fi

  if grep -qiE "conflict|409" /tmp/_cm_patch_err; then
    _retry=$(( _retry + 1 ))
    if [ "$_retry" -ge "$_max_retries" ]; then
      echo "ERROR: cp-config-global patch failed after $_max_retries retries (conflict)."
      cat /tmp/_cm_patch_err >&2
      exit 1
    fi
    sleep $(( (RANDOM % 3) + 1 ))
    echo "Conflict updating cp-config-global (retry $_retry/$_max_retries); re-reading..."
    continue
  fi

  cat /tmp/_cm_patch_err >&2
  exit 1
done
{{- end -}}

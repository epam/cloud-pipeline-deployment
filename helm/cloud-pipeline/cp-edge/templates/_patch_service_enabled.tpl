{{- define "cp-edge.patchServiceEnabled" }}
_cp_sv_out="cp-api-srv,cp-edge"
for _cp_sv_name in cp-idp cp-docker-registry cp-git cp-share-srv; do
if kubectl get "svc/${_cp_sv_name}" -n "$NAMESPACE" -o name &>/dev/null; then
  _cp_sv_out="${_cp_sv_out},${_cp_sv_name}"
fi
done
_cp_sv_patch=$(jq -n --arg k CP_SERVICES_ENABLED --arg v "$_cp_sv_out" '{data:{($k):$v}}')
kubectl patch configmap cp-config-global -n "$NAMESPACE" --type merge -p "$_cp_sv_patch" >/dev/null
echo "cp-edge hook: set CP_SERVICES_ENABLED (cluster discovery): ${_cp_sv_out}"
{{- end }}

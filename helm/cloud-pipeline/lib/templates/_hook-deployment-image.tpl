{{/*
  Container image for Helm hook Jobs (kubectl, jq, curl, openssl, etc.).
  Build from Temp/Dockerfile in this repo and push as this reference.
*/}}
{{- define "lib.hook.deploymentImage" -}}
quay.io/lifescience/cloud-pipeline:deployment-helm-hook
{{- end }}

{{/*
  Pull policy for the hook deployment image above.
  Override via general.hookImagePullPolicy in values.yaml (default: IfNotPresent, since
  the image usually can't be pushed to a registry and is instead built/tagged locally).
*/}}
{{- define "lib.hook.deploymentImagePullPolicy" -}}
{{- .Values.hookImagePullPolicy | default "IfNotPresent" -}}
{{- end }}

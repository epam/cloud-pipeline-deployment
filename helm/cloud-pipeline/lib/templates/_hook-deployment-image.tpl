{{/*
  Container image for Helm hook Jobs (kubectl, jq, curl, openssl, etc.).
  Build from Temp/Dockerfile in this repo and push as this reference.
*/}}
{{- define "lib.hook.deploymentImage" -}}
quay.io/lifescience/cloud-pipeline:deployment-helm-hook
{{- end }}

{{/*
  Returns the image pull secret name, or empty string when none is configured.
  - user+password set → "cp-distr-docker-registry-secret" (auto-created by cp-resources)
  - secret set       → the user-supplied pre-existing Secret name
  - neither          → ""
*/}}
{{- define "lib.imagePullSecretName" -}}
{{- $ipc := .Values.imagePullCredentials | default dict -}}
{{- $user := index $ipc "user" | default "" -}}
{{- $password := index $ipc "password" | default "" -}}
{{- if and $user $password -}}cp-distr-docker-registry-secret
{{- else -}}{{ index $ipc "secret" | default "" }}
{{- end -}}
{{- end -}}

{{/*
  Renders the imagePullSecrets block for pod specs.
  Renders nothing when no credentials are configured.
*/}}
{{- define "lib.imagePullSecret" -}}
{{- $name := include "lib.imagePullSecretName" . -}}
{{- if $name -}}
imagePullSecrets:
  - name: {{ $name }}
{{- end -}}
{{- end -}}

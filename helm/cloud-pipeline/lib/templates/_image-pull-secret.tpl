{{/*
  Renders imagePullSecrets block for pod specs when a private registry is configured.
  Uses "cp-distr-docker-registry-secret" (created by cp-resources) when user+password are set,
  or a pre-existing Secret when imagePullCredentials.secret is set.
  Renders nothing when imagePullCredentials is absent or all fields are empty.
*/}}
{{- define "lib.imagePullSecret" -}}
{{- $ipc := .Values.imagePullCredentials | default dict -}}
{{- $user := index $ipc "user" | default "" -}}
{{- $password := index $ipc "password" | default "" -}}
{{- $secret := index $ipc "secret" | default "" -}}
{{- $secretName := "" -}}
{{- if and $user $password -}}
  {{- $secretName = "cp-distr-docker-registry-secret" -}}
{{- else if $secret -}}
  {{- $secretName = $secret -}}
{{- end -}}
{{- if $secretName -}}
imagePullSecrets:
  - name: {{ $secretName }}
{{- end -}}
{{- end -}}

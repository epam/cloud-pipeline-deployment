{{/*
  Shared hook Job template that patches cp-config-global from a mounted ConfigMap.
  Each chart creates a hook ConfigMap named:
    configmap-to-update-{{ .Values.service.name }}
  with key/value pairs to apply into cp-config-global.
*/}}
{{- define "lib.cpConfigGlobal.patchHookTemplate" -}}
{{- $ctx := .context -}}
{{- $prePatchAdditionalScript := index . "prePatchAdditionalScript" | default "" | toString -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .jobName | default (printf "patch-config-global-%s" $ctx.Values.service.name) }}
  namespace: {{ include "lib.application.namespace" $ctx }}
  annotations:
    "helm.sh/hook": pre-install, pre-upgrade
    "helm.sh/hook-weight": {{ .hookWeight | default "-10" | quote }}
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  backoffLimit: 0
  activeDeadlineSeconds: {{ .activeDeadlineSeconds | default 600 }}
  template:
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      serviceAccountName: {{ include "lib.hook.serviceaccount" $ctx }}
      restartPolicy: Never
      volumes:
        - name: patch-data
          configMap:
            name: {{ printf "configmap-to-update-%s" $ctx.Values.service.name }}
      containers:
        - name: patch
          image: {{ include "lib.hook.deploymentImage" $ctx }}
          imagePullPolicy: IfNotPresent
          env:
            - name: NAMESPACE
              value: {{ include "lib.application.namespace" $ctx | quote }}
          volumeMounts:
            - name: patch-data
              mountPath: /etc/cp-config-global-patch
              readOnly: true
          command: ["/bin/bash", "-c"]
          args:
            - |
{{ include "lib.cpConfigGlobal.patchScript" (dict "context" $ctx "prePatchAdditionalScript" $prePatchAdditionalScript "serviceName" $ctx.Values.service.name) | indent 14 }}
{{- end }}

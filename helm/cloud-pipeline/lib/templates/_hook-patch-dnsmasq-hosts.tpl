{{/* Post-install Job: add external service IP to cp-dnsmasq-hosts for kube-dns. */}}
{{- define "lib.patchDNSJob" -}}
{{- if .Values.patchDNS.enabled -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: patch-dnsmasq-hosts-{{ .Chart.Name }}-{{ lower (randAlphaNum 8) }}
  namespace: {{ include "lib.application.namespace" . }}
  annotations:
    "helm.sh/hook": post-install
    "helm.sh/hook-weight": "-100"
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1200
  template:
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      restartPolicy: Never
      serviceAccountName: {{ include "lib.hook.serviceaccount" . }}
      containers:
        - name: patch-dnsmasq
          image: {{ .Values.patchDNS.image | default (include "lib.hook.deploymentImage" .) }}
          imagePullPolicy: IfNotPresent
          env:
            - name: NAMESPACE
              value: {{ include "lib.application.namespace" . | quote }}
            - name: SVC
              value: {{ .Values.service.name | quote }}
            - name: HOST
              value: {{ .Values.service.host.external | quote }}
          command: ["/bin/bash", "-c"]
          args:
            - |
{{ include "lib.patchDNSScript" . | indent 14 }}

{{- end -}}
{{- end -}}

{{/* Post-install/post-upgrade Job: add static IP→host entries to cp-dnsmasq-hosts. */}}
{{- define "lib.patchDNSStaticJob" -}}
{{- if .Values.customDNS.entries -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: patch-dnsmasq-static-{{ lower (randAlphaNum 8) }}
  namespace: {{ include "lib.application.namespace" . }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "-100"
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1200
  template:
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      restartPolicy: Never
      serviceAccountName: {{ include "lib.hook.serviceaccount" . }}
      containers:
        - name: patch-dnsmasq-static
          image: {{ include "lib.hook.deploymentImage" . }}
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
{{ include "lib.patchDNSStaticScript" . | indent 14 }}

{{- end -}}
{{- end -}}
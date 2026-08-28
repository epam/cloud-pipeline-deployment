{{/* Backup worker Deployment for a given service.
     Args (dict): context, serviceName, serviceWd, kubectlArgs (optional),
                  initContainers (optional) — name of a named template that renders
                  the initContainers list; receives the same dict as this template.
                  When omitted, defaults to a single wait-for-api-token init container.
     Renders nothing when .context.Values.backup.enabled is false. */}}
{{- define "lib.backupWorker.deployment" -}}
{{- $ctx := .context -}}
{{- $serviceName := .serviceName -}}
{{- $serviceWd := .serviceWd -}}
{{- $kubectlArgs := .kubectlArgs | default "" -}}
{{- $initContainers := .initContainers | default "" -}}
{{- if $ctx.Values.backup.enabled -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cp-bkp-worker-{{ $serviceName }}
  namespace: {{ include "lib.application.namespace" $ctx }}
  labels:
    app: cp-bkp-worker-{{ $serviceName }}
spec:
  replicas: 1
  # Recreate: hostPath backup working directory cannot be shared between old and new pod simultaneously.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: cp-bkp-worker-{{ $serviceName }}
  template:
    metadata:
      annotations:
        deploy-timestamp: "{{ now | date "2006-01-02_15:04:05" }}"
      labels:
        app: cp-bkp-worker-{{ $serviceName }}
    spec:
      {{- include "lib.imagePullSecret" $ctx | nindent 6 }}
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      serviceAccountName: {{ include "lib.hook.serviceaccount" $ctx }}
      nodeSelector:
        cloud-pipeline/{{ $serviceName }}: "true"
      initContainers:
        {{- if $initContainers }}
        {{- include $initContainers . | nindent 8 }}
        {{- else }}
        - name: wait-for-api-token
          image: {{ include "lib.hook.deploymentImage" $ctx }}
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
              secret="{{ include "lib.cpApiTokenSecretName" $ctx }}"
              namespace="{{ include "lib.application.namespace" $ctx }}"
              echo "Waiting for $secret to contain CP_API_JWT_ADMIN..."
              until kubectl get secret "$secret" -n "$namespace" \
                -o jsonpath='{.data.CP_API_JWT_ADMIN}' 2>/dev/null | grep -q .; do
                echo "  not ready, retrying in 10s"
                sleep 10
              done
              echo "CP_API_JWT_ADMIN is set in $secret, proceeding."
        {{- end }}
      containers:
        - name: cp-bkp-worker
          {{- $imageVersion := required "buildVersion must be set (set general.buildVersion in values.yaml. You also can override specific value with image.buildVersion value for each service pod)" (coalesce $ctx.Values.backup.image.buildVersion $ctx.Values.buildVersion "") }}
          {{- $imageRef := ternary (printf "%s@%s" $ctx.Values.backup.image.repository $ctx.Values.backup.image.tag) (printf "%s:%s-%s" $ctx.Values.backup.image.repository $ctx.Values.backup.image.tag $imageVersion) (hasPrefix "sha256:" $ctx.Values.backup.image.tag) }}
          image: {{ $imageRef }}
          imagePullPolicy: {{ $ctx.Values.backup.image.pullPolicy }}
          env:
            - name: CP_BKP_SERVICE_NAME
              value: {{ $serviceName | quote }}
            - name: CP_BKP_SERVICE_WD
              value: {{ printf "%s/bkp-worker-wd" $serviceWd | quote }}
            {{- if $kubectlArgs }}
            - name: CP_BKP_SERVICE_KUBECTL_ARGS
              value: {{ $kubectlArgs | quote }}
            {{- end }}
            - name: CP_BKP_SCHEDULE_CRON
              value: {{ $ctx.Values.backup.schedule | quote }}
            - name: CP_BKP_FILES_COUNT
              value: {{ $ctx.Values.backup.retention | quote }}
            {{- if $ctx.Values.backup.storageList }}
            - name: CP_BKP_STORAGE_LIST
              value: {{ $ctx.Values.backup.storageList | quote }}
            {{- end }}
            - name: CP_API_JWT_ADMIN
              valueFrom:
                secretKeyRef:
                  name: {{ include "lib.cpApiTokenSecretName" $ctx }}
                  key: CP_API_JWT_ADMIN
          envFrom:
            - configMapRef:
                name: cp-config-global
          volumeMounts:
            - name: bkp-wd
              mountPath: {{ printf "%s/bkp-worker-wd" $serviceWd }}
            - name: logs
              mountPath: /opt/bkp-worker/logs
      volumes:
        - name: bkp-wd
          hostPath:
            path: {{ printf "%s/bkp-worker-wd" $serviceWd }}
        - name: logs
          hostPath:
            path: /opt/bkp-worker/logs
{{- end -}}
{{- end -}}

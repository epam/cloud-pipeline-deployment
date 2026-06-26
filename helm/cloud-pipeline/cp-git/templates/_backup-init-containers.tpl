{{/* Init containers for cp-git backup workers.
     Waits for the API token secret, then waits for the target deployment to roll out.
     Args (dict): same dict passed to lib.backupWorker.deployment
                  (context, serviceName, serviceWd, …). */}}
{{- define "cp-git.bkpWorkerInitContainers" -}}
{{- $ctx := .context -}}
{{- $serviceName := .serviceName -}}
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
- name: wait-for-deployment
  image: {{ include "lib.hook.deploymentImage" $ctx }}
  imagePullPolicy: IfNotPresent
  command: ["/bin/bash", "-c"]
  args:
    - |
      namespace="{{ include "lib.application.namespace" $ctx }}"
      echo "Waiting for deployment/{{ $serviceName }} to be ready..."
      kubectl rollout status deployment/{{ $serviceName }} -n "$namespace" --timeout=1800s
      echo "deployment/{{ $serviceName }} is ready."
{{- end -}}

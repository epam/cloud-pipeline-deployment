set -euo pipefail

params_file=$(mktemp)
trap 'rm -f "$params_file"' EXIT
echo "${params_b64}" | base64 -d > "$params_file"

# A freshly created instance isn't an SSM target yet: the EC2 API reports it "running" well
# before its SSM Agent finishes booting and registers with the SSM service. Poll until it's
# actually online instead of letting the first send-command fail outright.
elapsed=0
until [ "$(aws ssm describe-instance-information \
  --region "${region}" \
  --filters "Key=InstanceIds,Values=${instance_id}" \
  --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null)" = "Online" ]; do
  if [ "$elapsed" -ge ${timeout} ]; then
    echo "Timed out after ${timeout}s waiting for ${instance_id} to register with SSM" >&2
    exit 1
  fi
  sleep ${poll_interval}
  elapsed=$((elapsed + ${poll_interval}))
done

command_id=$(aws ssm send-command \
  --region "${region}" \
  --instance-ids "${instance_id}" \
  --document-name "AWS-RunShellScript" \
  --parameters "file://$params_file" \
  --query "Command.CommandId" --output text)
aws ssm wait command-executed \
  --region "${region}" \
  --command-id "$command_id" \
  --instance-id "${instance_id}"

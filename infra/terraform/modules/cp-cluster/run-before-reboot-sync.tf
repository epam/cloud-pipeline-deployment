# Pushes the current run-before-reboot script to every already-running node via SSM Run Command,
# whenever its content actually changes. 
# Requires the "aws" CLI to be installed and authenticated wherever `terraform apply` runs.
locals {
  run_before_reboot_sync_targets = merge(
    { master = aws_instance.master.id },
    { for idx, id in aws_instance.application[*].id : "application-${idx}" => id }
  )

  run_before_reboot_sync_commands = [
    "echo ${base64encode(local.run_before_reboot_script)} | base64 -d > /usr/local/bin/cp-run-before-reboot.sh",
    "chmod +x /usr/local/bin/cp-run-before-reboot.sh",
  ]

  # Same reasoning as security_patch_ssm_params_b64 in security-patch-schedule.tf: base64 has no
  # quotes/backslashes in its alphabet, so this can be embedded in the heredoc below and written
  # out with a plain `echo | base64 -d` -- no shell-quoting of the commands' own quotes/
  # backslashes needed.
  run_before_reboot_sync_params_b64 = base64encode(jsonencode({ commands = local.run_before_reboot_sync_commands }))

  # Content hash, not the schedule-style variable security-patch-schedule.tf uses: this hook has
  # no on/off toggle, so what should trigger a re-sync is the rendered content itself changing.
  run_before_reboot_content_hash = md5(local.run_before_reboot_script)
}

resource "null_resource" "run_before_reboot_sync" {
  for_each = local.run_before_reboot_sync_targets

  triggers = {
    content_hash = local.run_before_reboot_content_hash
    instance_id  = each.value
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      params_file=$(mktemp)
      trap 'rm -f "$params_file"' EXIT
      echo "${local.run_before_reboot_sync_params_b64}" | base64 -d > "$params_file"

      # Same reasoning as security-patch-schedule.tf: a freshly created instance isn't an SSM
      # target yet, so poll until it actually is instead of letting the first send-command fail.
      elapsed=0
      timeout=300
      until [ "$(aws ssm describe-instance-information \
        --region "${data.aws_region.current.region}" \
        --filters "Key=InstanceIds,Values=${each.value}" \
        --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null)" = "Online" ]; do
        if [ "$elapsed" -ge "$timeout" ]; then
          echo "Timed out after $${timeout}s waiting for ${each.value} to register with SSM" >&2
          exit 1
        fi
        sleep 10
        elapsed=$((elapsed + 10))
      done

      command_id=$(aws ssm send-command \
        --region "${data.aws_region.current.region}" \
        --instance-ids "${each.value}" \
        --document-name "AWS-RunShellScript" \
        --parameters "file://$params_file" \
        --query "Command.CommandId" --output text)
      aws ssm wait command-executed \
        --region "${data.aws_region.current.region}" \
        --command-id "$command_id" \
        --instance-id "${each.value}"
    EOT
  }
}

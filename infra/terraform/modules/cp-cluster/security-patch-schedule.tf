# Changes the dnf-automatic security-patch schedule (baked into the AMI by
# packer/common/scripts/install_security_patches.sh) on every already-running node via SSM Run
# Command, in this same terraform apply -- no AMI rebuild or instance replacement needed, and no
# SSH/bastion/VPN connectivity to the nodes: traffic goes over the AWS API, using the
# AmazonSSMManagedInstanceCore permissions every node's instance profile already has (see
# iam.tf). Entirely opt-in: when var.security_patch_schedule is left unset,
# local.security_patch_schedule_targets is empty and nothing is created.
#
# Requires the "aws" CLI to be installed and authenticated wherever `terraform apply` runs.
locals {
  security_patch_schedule_targets = var.security_patch_schedule == null ? {} : merge(
    { master = aws_instance.master.id },
    { for idx, id in aws_instance.application[*].id : "application-${idx}" => id }
  )

  # Guarded the same way as security_patch_schedule_targets above: locals are evaluated
  # unconditionally regardless of whether any null_resource instance ends up using them, so
  # interpolating var.security_patch_schedule directly here would fail plan/apply with "Cannot
  # include a null value in a string template" whenever the variable is left unset.
  security_patch_ssm_commands = var.security_patch_schedule == null ? [] : [
    "sed -i 's|OnCalendar=.*\\*.*|OnCalendar=${var.security_patch_schedule}|' /etc/systemd/system/dnf-automatic.timer.d/override.conf",
    "systemctl daemon-reload",
    "systemctl restart dnf-automatic.timer",
  ]

  # base64 has no quotes/backslashes in its alphabet, so this can be embedded in the heredoc
  # below and written out with a plain `echo | base64 -d` -- no shell-quoting of the sed
  # command's own quotes/backslashes needed.
  security_patch_ssm_params_b64 = base64encode(jsonencode({ commands = local.security_patch_ssm_commands }))
}

resource "null_resource" "security_patch_schedule" {
  for_each = local.security_patch_schedule_targets

  triggers = {
    schedule    = var.security_patch_schedule
    instance_id = each.value
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      params_file=$(mktemp)
      trap 'rm -f "$params_file"' EXIT
      echo "${local.security_patch_ssm_params_b64}" | base64 -d > "$params_file"

      # A freshly created instance isn't an SSM target yet: the EC2 API reports it "running"
      # well before its SSM Agent finishes booting and registers with the SSM service. Poll
      # until it's actually online instead of letting the first send-command fail outright.
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

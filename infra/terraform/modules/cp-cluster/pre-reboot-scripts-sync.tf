# Keeps /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/ in sync per node role, via SSM
# Run Command on every already-running node -- no AMI rebuild or instance replace needed:
#   - var.pre_reboot_scripts: symlinks (or removes the symlink for) each built-in script already
#     baked into the AMI (packer/common/scripts/reboot/pre_reboot_scripts/*.sh).
#   - var.custom_pre_reboot_scripts: additionally pushes the content of each user-supplied local
#     script, makes it executable, and symlinks it in too -- these aren't baked into the AMI at
#     all, so unlike the built-in ones they have no "disable" state, only present or absent.
locals {
  pre_reboot_sync_targets = merge(
    { master = { instance_id = aws_instance.master.id, role = "master" } },
    { for idx, id in aws_instance.application[*].id : "application-${idx}" => { instance_id = id, role = "application" } }
  )

  pre_reboot_builtin_commands = {
    for role, scripts in var.pre_reboot_scripts :
    role => [
      for script_name, enabled in scripts :
      enabled
      ? "ln -sf ../${script_name}.sh /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/${role}/${script_name}.sh"
      : "rm -f /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/${role}/${script_name}.sh"
    ]
  }

  custom_pre_reboot_script_contents = {
    for role in ["master", "application"] :
    role => { for p in lookup(var.custom_pre_reboot_scripts, role, []) : basename(p) => file(p) }
  }

  custom_pre_reboot_commands = {
    for role, scripts in local.custom_pre_reboot_script_contents :
    role => flatten([
      for script_name, content in scripts : [
        "echo ${base64encode(content)} | base64 -d > /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/${script_name}",
        "chmod +x /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/${script_name}",
        "ln -sf ../${script_name} /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/${role}/${script_name}",
      ]
    ])
  }

  pre_reboot_sync_commands = {
    for key, target in local.pre_reboot_sync_targets :
    key => concat(
      lookup(local.pre_reboot_builtin_commands, target.role, []),
      lookup(local.custom_pre_reboot_commands, target.role, [])
    )
  }

  # Same reasoning as security_patch_ssm_params_b64 in security-patch-schedule.tf: base64 has no
  # quotes/backslashes in its alphabet, so this can be embedded in the heredoc below and written
  # out with a plain `echo | base64 -d` -- no shell-quoting of the commands' own quotes/
  # backslashes needed.
  pre_reboot_sync_params_b64 = {
    for key, commands in local.pre_reboot_sync_commands :
    key => base64encode(jsonencode({ commands = commands }))
  }

  # Content hash, not a toggle variable: what should trigger a re-sync is the resolved command set
  # for that role actually changing.
  pre_reboot_sync_content_hash = {
    for key, commands in local.pre_reboot_sync_commands :
    key => md5(jsonencode(commands))
  }
}

resource "null_resource" "pre_reboot_scripts_sync" {
  for_each = local.pre_reboot_sync_targets

  triggers = {
    content_hash = local.pre_reboot_sync_content_hash[each.key]
    instance_id  = each.value.instance_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      params_file=$(mktemp)
      trap 'rm -f "$params_file"' EXIT
      echo "${local.pre_reboot_sync_params_b64[each.key]}" | base64 -d > "$params_file"

      # Same reasoning as security-patch-schedule.tf: a freshly created instance isn't an SSM
      # target yet, so poll until it actually is instead of letting the first send-command fail.
      elapsed=0
      timeout=300
      until [ "$(aws ssm describe-instance-information \
        --region "${data.aws_region.current.region}" \
        --filters "Key=InstanceIds,Values=${each.value.instance_id}" \
        --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null)" = "Online" ]; do
        if [ "$elapsed" -ge "$timeout" ]; then
          echo "Timed out after $${timeout}s waiting for ${each.value.instance_id} to register with SSM" >&2
          exit 1
        fi
        sleep 10
        elapsed=$((elapsed + 10))
      done

      command_id=$(aws ssm send-command \
        --region "${data.aws_region.current.region}" \
        --instance-ids "${each.value.instance_id}" \
        --document-name "AWS-RunShellScript" \
        --parameters "file://$params_file" \
        --query "Command.CommandId" --output text)
      aws ssm wait command-executed \
        --region "${data.aws_region.current.region}" \
        --command-id "$command_id" \
        --instance-id "${each.value.instance_id}"
    EOT
  }
}

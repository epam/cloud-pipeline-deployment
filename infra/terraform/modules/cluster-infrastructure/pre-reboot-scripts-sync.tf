# Keeps /var/lib/cloud-pipeline/system-updates/pre_reboot_scripts/ in sync per node role, via SSM
# Run Command on every already-running node -- no AMI rebuild or instance replace needed:
#   - var.pre_reboot_scripts: symlinks (or removes the symlink for) each built-in script already
#     baked into the AMI (packer/common/scripts/reboot/pre_reboot_scripts/*.sh).
#   - var.custom_pre_reboot_scripts: additionally pushes the content of each user-supplied local
#     script, makes it executable, and symlinks it in too -- these aren't baked into the AMI at
#     all, so unlike the built-in ones they have no "disable" state, only present or absent.
locals {
  pre_reboot_sync_targets_all = merge(
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

  # Iterates over an empty list (rather than a `var.enable_ssm_run_commands ? ... : {}` ternary)
  # when disabled, so that file() below is never evaluated -- unlike a `for`, a ternary's unused
  # branch is still evaluated by Terraform and would error out anyway.
  custom_pre_reboot_script_contents = {
    for role in(var.enable_ssm_run_commands ? ["master", "application"] : []) :
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
    for key, target in local.pre_reboot_sync_targets_all :
    key => concat(
      lookup(local.pre_reboot_builtin_commands, target.role, []),
      lookup(local.custom_pre_reboot_commands, target.role, [])
    )
  }

  # Skipped per node when its command list is empty, or entirely when var.enable_ssm_run_commands
  # is false (see terraform.tfvars.example and ../../README.md for details).
  pre_reboot_sync_targets = var.enable_ssm_run_commands ? {
    for key, target in local.pre_reboot_sync_targets_all :
    key => target if length(local.pre_reboot_sync_commands[key]) > 0
  } : {}
}

module "pre_reboot_scripts_sync" {
  source   = "../ssm-run-command"
  for_each = local.pre_reboot_sync_targets

  region      = data.aws_region.current.region
  instance_id = each.value.instance_id
  commands    = local.pre_reboot_sync_commands[each.key]
}

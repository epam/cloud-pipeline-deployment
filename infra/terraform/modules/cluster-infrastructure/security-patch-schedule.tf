# Changes the dnf-automatic security-patch schedule (baked into the AMI by
# packer/common/scripts/install_security_patches.sh) on every already-running node via SSM Run
# Command, in this same terraform apply -- no AMI rebuild or instance replacement needed, and no
# SSH/bastion/VPN connectivity to the nodes: traffic goes over the AWS API, using the
# AmazonSSMManagedInstanceCore permissions every node's instance profile already has (see
# iam.tf). Skipped when var.security_patch_schedule is unset or var.enable_ssm_run_commands is
# false (see terraform.tfvars.example and ../../README.md for details).
#
# Requires the "aws" CLI to be installed and authenticated wherever `terraform apply` runs.
locals {
  security_patch_schedule_targets = (var.enable_ssm_run_commands && var.security_patch_schedule != null) ? merge(
    { master = aws_instance.master.id },
    { for idx, id in aws_instance.application[*].id : "application-${idx}" => id }
  ) : {}

  # Guarded the same way as security_patch_schedule_targets above: locals are evaluated
  # unconditionally regardless of whether any module instance ends up using them, so
  # interpolating var.security_patch_schedule directly here would fail plan/apply with "Cannot
  # include a null value in a string template" whenever the variable is left unset.
  security_patch_ssm_commands = var.security_patch_schedule == null ? [] : [
    "sed -i 's|OnCalendar=.*\\*.*|OnCalendar=${var.security_patch_schedule}|' /etc/systemd/system/dnf-automatic.timer.d/override.conf",
    "systemctl daemon-reload",
    "systemctl restart dnf-automatic.timer",
  ]
}

module "security_patch_schedule" {
  source   = "../ssm-run-command"
  for_each = local.security_patch_schedule_targets

  region      = data.aws_region.current.region
  instance_id = each.value
  commands    = local.security_patch_ssm_commands

  triggers = {
    schedule = var.security_patch_schedule
  }
}

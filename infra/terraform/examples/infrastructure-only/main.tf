module "cluster_infrastructure" {
  # To pin this to a released version from another repository, replace with:
  # source = "git::https://github.com/epam/cloud-pipeline-deployment//infra/terraform/modules/cluster-infrastructure?ref=<tag-or-commit>"
  source = "../../modules/cluster-infrastructure"

  # Provisions only the raw infrastructure -- no helm-deployment-values module call, so no Cloud
  # Pipeline application hostnames, admin credentials, or generated values.yaml. See ../complete
  # for a helm-ready example that adds that module alongside this one.

  deployment_name = var.deployment_name
  deployment_env  = var.deployment_env

  vpc_id                             = var.vpc_id
  subnet_ids                         = var.subnet_ids
  external_access_security_group_ids = var.external_access_security_group_ids

  ami_id   = var.ami_id
  key_name = var.key_name

  master_node_instance_type      = var.master_node_instance_type
  application_node_instance_type = var.application_node_instance_type
  application_node_count         = var.application_node_count

  storage_type = var.storage_type

  enable_ssm_run_commands = var.enable_ssm_run_commands
  security_patch_schedule = var.security_patch_schedule
  pre_reboot_scripts      = var.pre_reboot_scripts

  # custom_pre_reboot_scripts entries are read with file() inside the module, so they must be
  # absolute paths. .tfvars files don't support function calls (not even path-only ones like
  # abspath()), so var.custom_pre_reboot_scripts holds bare filenames and they're resolved to
  # absolute paths here instead, where path.root is available.
  custom_pre_reboot_scripts = {
    for role, files in var.custom_pre_reboot_scripts :
    role => [for f in files : "${path.root}/${f}"]
  }
}

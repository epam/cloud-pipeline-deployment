module "cp_cluster" {
  # To pin this to a released version from another repository, replace with:
  # source = "git::https://<your-git-host>/cloud-pipeline-deployment//infra/terraform/modules/cp-cluster?ref=<tag-or-commit>"
  source = "../../modules/cp-cluster"

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

  api_srv_host         = var.api_srv_host
  docker_registry_host = var.docker_registry_host
  edge_host            = var.edge_host
  git_host             = var.git_host
  idp_host             = var.idp_host
  share_srv_host       = var.share_srv_host

  admin_email    = var.admin_email
  admin_password = var.admin_password

  docker_tools = var.docker_tools

  worker_node_amis               = var.worker_node_amis
  worker_node_security_group_ids = var.worker_node_security_group_ids

  security_patch_schedule = var.security_patch_schedule

  # custom_pre_reboot_scripts entries are read with file() inside the module, so they must be
  # absolute paths. .tfvars files don't support function calls (not even path-only ones like
  # abspath()), so var.custom_pre_reboot_scripts holds bare filenames and they're resolved to
  # absolute paths here instead, where path.root is available.
  custom_pre_reboot_scripts = {
    for role, files in var.custom_pre_reboot_scripts :
    role => [for f in files : "${path.root}/${f}"]
  }
}

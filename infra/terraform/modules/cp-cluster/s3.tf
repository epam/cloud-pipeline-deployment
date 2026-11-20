# Backend storage for the internal Docker registry (CP_DOCKER_STORAGE_CONTAINER).
module "s3_docker_registry" {
  count   = var.create_s3_buckets ? 1 : 0
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.18.0"

  bucket                   = coalesce(var.docker_registry_bucket_name, "${local.resource_name_prefix}-docker")
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"
  force_destroy            = var.s3_force_destroy

  lifecycle_rule = [
    {
      id      = "abort-incomplete-multipart-uploads"
      enabled = true
      filter = {
        prefix = ""
      }
      abort_incomplete_multipart_upload_days = 5
    }
  ]

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.kms.key_arn
        sse_algorithm     = "aws:kms"
      }
    }
  }

  tags = merge(local.tags, { Type = "docker-registry" })
}

# System storage: issue attachments, FSBrowser transfers, run logs, search
# index backups, platform backup (CP_PREF_STORAGE_SYSTEM_STORAGE_NAME).
module "s3_system_storage" {
  count   = var.create_s3_buckets ? 1 : 0
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.18.0"

  bucket                   = coalesce(var.system_bucket_name, "${local.resource_name_prefix}-system")
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"
  force_destroy            = var.s3_force_destroy

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = module.kms.key_arn
        sse_algorithm     = "aws:kms"
      }
    }
  }

  tags = merge(local.tags, { Type = "system-storage" })
}

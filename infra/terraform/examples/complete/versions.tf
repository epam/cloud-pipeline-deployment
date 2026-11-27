terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.29"
    }
  }

  # Configure a remote backend before running this in production -- a local
  # state file cannot be safely shared between teammates or CI. Create the
  # bucket and lock table once, up front (see infra/terraform/README.md
  # "Prerequisites"), then uncomment:
  #
  # backend "s3" {
  #   bucket         = "<your-terraform-state-bucket>"
  #   key            = "cloud-pipeline/terraform.tfstate"
  #   region         = "<your-state-bucket-region>"
  #   dynamodb_table = "<your-terraform-lock-table>"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region
}

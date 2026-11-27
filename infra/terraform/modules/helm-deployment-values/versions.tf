# This module intentionally declares no `backend` and no `provider` blocks.
# Both must be configured by the root module that calls it (see ../../examples/complete).

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.29"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

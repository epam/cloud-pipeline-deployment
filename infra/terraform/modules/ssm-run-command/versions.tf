# This module intentionally declares no `backend` and no `provider` blocks.
# Both must be configured by the root module that calls it (see ../../examples/single-cluster).

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}

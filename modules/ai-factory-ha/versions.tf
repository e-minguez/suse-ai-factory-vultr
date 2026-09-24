terraform {
  # terraform_data (snapshot.tf) shipped in 1.4; var.vpc_subnet's validation
  # references another variable (vpc_subnet_mask), which only became legal in
  # 1.9 -- before that it is a hard "Invalid reference in variable validation".
  required_version = ">= 1.9"

  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.32" # vpc_only (2.32.0) and vultr_nat_gateway (2.29.0)
    }

    # availability.tf's pre-flight checks use the retry block.
    http = {
      source  = "hashicorp/http"
      version = ">= 3.5"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    # time_static (snapshot.tf) pins the build's timestamp at create time;
    # timestamp() would re-evaluate on every plan.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

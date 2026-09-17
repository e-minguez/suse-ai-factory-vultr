terraform {
  # terraform_data (used by the module's snapshot wait) shipped in 1.4; the
  # module's vpc_subnet validation cross-references another variable, which
  # needs 1.9.
  required_version = ">= 1.9"

  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.32"
    }
  }
}

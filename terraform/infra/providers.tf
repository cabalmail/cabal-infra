provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      environment          = var.environment
      managed_by_terraform = "y"
      terraform_repo       = var.repo
    }
  }
}

# Second-region provider for the disaster-recovery backup vault (the
# backup module's copy_action destination). Configured unconditionally
# so the provider graph is stable, but nothing uses it unless
# var.backup is true.
provider "aws" {
  alias  = "dr_region"
  region = var.dr_region
  default_tags {
    tags = {
      environment          = var.environment
      managed_by_terraform = "y"
      terraform_repo       = var.repo
    }
  }
}

# Route 53 requires the KMS key backing a DNSSEC key-signing key to
# live in us-east-1, regardless of where the rest of the stack runs.
# Only the domains module's dnssec.tf uses this alias, and only when
# var.dnssec_enabled is true.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  default_tags {
    tags = {
      environment          = var.environment
      managed_by_terraform = "y"
      terraform_repo       = var.repo
    }
  }
}

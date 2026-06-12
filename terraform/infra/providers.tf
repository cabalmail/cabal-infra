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

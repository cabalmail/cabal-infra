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

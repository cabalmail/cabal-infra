terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.33.0"
    }
    git = {
      source  = "innovationnorway/terraform-provider-git"
      version = "~> "
    }
  }

  required_version = ">= 0.15.0"
}

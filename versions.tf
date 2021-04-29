terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.33.0"
    }
    git = {
      source  = "innovationnorway/git"
      version = "~> 0.1.3"
    }
  }

  required_version = ">= 0.15.0"
}

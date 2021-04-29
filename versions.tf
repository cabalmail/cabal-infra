terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.33.0"
    }
    git = {}
  }

  required_version = ">= 0.15.0"
}

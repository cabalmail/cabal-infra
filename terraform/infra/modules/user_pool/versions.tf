terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.32"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }

  required_version = ">= 1.1.2"
}

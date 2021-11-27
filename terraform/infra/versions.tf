terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.57.0"
    }
    aws  = {
      source  = "hashicorp/aws"
      version = "~> 3.33.0"
    }
  }

  required_version = ">= 1.0.0"
}

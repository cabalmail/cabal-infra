terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.28.0"
    }
    time = {
      source = "hashicorp/time"
      version = "0.5.0"
    }
  }

  required_version = ">= 0.15.0"
}

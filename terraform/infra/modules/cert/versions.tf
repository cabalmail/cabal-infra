terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.67.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "2.2.0"
    }
  }

  required_version = ">= 1.0.0"
}

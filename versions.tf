terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.28.0"
    }
    acme = {
      source = "vancluever/acme"
      version = "2.2.0"
    }
  }

  required_version = ">= 0.14.0"
}

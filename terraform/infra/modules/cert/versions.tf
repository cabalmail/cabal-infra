terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.32.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "2.2.0"
    }
  }

  required_version = ">= 1.1.2"
}

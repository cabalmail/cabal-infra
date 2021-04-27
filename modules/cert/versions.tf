terraform {
  required_providers {
    acme = {
      source  = "vancluever/acme"
      version = "2.2.0"
    }
    aws  = {
      source  = "hashicorp/aws"
      version = "~> 3.28.0"
    }
  }

  required_version = ">= 0.15.0"
}

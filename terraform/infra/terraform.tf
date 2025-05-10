terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.94.1"
    }
    acme = {
      source  = "vancluever/acme"
      version = "2.2.0"
    }
  }
  required_version = ">= 1.1.2"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    twilio = {
      source  = "twilio/twilio"
      version = "~> 0.19"
    }
  }
  required_version = ">= 1.9.0"
}

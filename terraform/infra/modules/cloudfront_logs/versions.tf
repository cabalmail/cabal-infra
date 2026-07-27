terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # aws_cloudwatch_log_delivery* (CloudWatch vended-log delivery)
      # landed in provider 5.36.
      version = ">= 5.36"
    }
  }

  required_version = ">= 1.1.2"
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.28 added invoked_via_function_url on aws_lambda_permission.
      version = ">= 6.28"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }

  required_version = ">= 1.1.2"
}

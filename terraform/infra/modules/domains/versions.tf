terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.32"
      # us-east-1 provider for the DNSSEC KMS key (Route 53 requires
      # the KSK's KMS key to live in us-east-1); configured at the
      # root and passed in via the module's providers map.
      configuration_aliases = [aws.use1]
    }
  }

  required_version = ">= 1.1.2"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.32"
      # The DR-region provider is configured at the root (region =
      # var.dr_region) and passed in via the module's providers map;
      # declaring the alias here is what lets a count-ed module receive
      # it.
      configuration_aliases = [aws.dr_region]
    }
  }

  required_version = ">= 1.1.2"
}

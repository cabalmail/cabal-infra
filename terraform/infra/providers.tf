provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      environment          = var.environment
      managed_by_terraform = "y"
      terraform_repo       = var.repo
    }
  }
}

provider "twilio" {
  # Credentials come from environment variables:
  # TWILIO_ACCOUNT_SID, TWILIO_API_KEY, TWILIO_API_SECRET
}

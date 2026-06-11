data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_iam_policy_document" "users" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cognito-idp.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "sns_users" {
  # Cognito SMS (sns:Publish to a phone number) has no resource ARN to scope
  # to, so the wildcard resource is required, not a finding to fix. Inline
  # design suppression; see terraform/infra/BASELINE.md.
  #checkov:skip=CKV_AWS_111:SMS direct-publish has no resource ARN, so "*" is required
  #checkov:skip=CKV_AWS_356:SMS direct-publish has no resource ARN, so "*" is required
  statement {
    actions = [
      "sns:Publish",
    ]
    #tfsec:ignore:aws-iam-no-policy-wildcards
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "cognito_to_s3" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["message-cache/${"$"}{cognito-identity.amazonaws.com:sub}/*"]
    }
  }
  statement {
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::admin.${var.control_domain}/message-cache/${"$"}{cognito-identity.amazonaws.com:sub}/*"
    ]
  }
}

variable "bucket_arn" {
  type        = string
  description = "ARN of S3 bucket for React app"
}

variable "bucket" {
  type        = string
  description = "Name of S3 bucket for React app"
}

variable "control_domain" {
  type        = string
  description = "Base for auth domain. E.g., if control_domain is example.com, then the autho domain will be auth.example.com."
}

variable "ecs_cluster_name" {
  type        = string
  description = "Name of the ECS cluster. Used by assign_osid Lambda to force new deployments on user creation."
}

variable "healthcheck_ping_param" {
  type        = string
  description = "SSM Parameter Store name holding the Healthchecks ping URL for the assign_osid Lambda. Empty string disables the heartbeat."
  default     = ""
}

variable "use_eum_sms" {
  type        = bool
  description = "Feature flag: when true, provision the AWS End User Messaging toll-free phone number that backs SNS-based SMS delivery. When false, no EUM phone number is created."
  default     = false
}

variable "invitation_code" {
  type        = string
  description = "Shared secret that new users must supply on the signup form. Surfaced to the check_invite pre-signup Lambda as the INVITATION_CODE env var. Empty string disables the check and allows all signups."
  sensitive   = true
  default     = ""
}
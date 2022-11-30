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
  statement {
    actions = [
      "sns:Publish",
    ]
    #tfsec:ignore:aws-iam-no-policy-wildcards
    resources = [
      "arn:aws:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*",
    ]
  }
}

data "aws_iam_policy_document" "cognito_to_s3" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.bucket.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["message-cache/${"$"}{cognito-identity.amazonaws.com:sub}/*"]
    }
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${var.bucket.id}/message-cache/${"$"}{cognito-identity.amazonaws.com:sub}/*"
    ]
  }
}

variable "bucket" {
  type        = map
  description = "S3 bucket for React app"
}
variable "control_domain" {
  type        = string
  description = "Base for auth domain. E.g., if control_domain is example.com, then the autho domain will be auth.example.com."
}

variable "zone_id" {
  type        = string
  description = "Zone ID for creating DNS records for auth domain."
}
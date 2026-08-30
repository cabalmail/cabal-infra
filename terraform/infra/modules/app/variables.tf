data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

variable "user_pool_id" {
  type        = string
  description = "ID of the Cognito user pool."
}

variable "user_pool_client_id" {
  type        = string
  description = "Client ID for authenticating with the Cognito user pool."
}

variable "mfa_enroll_client_id" {
  type        = string
  description = "Client ID for the locked-out MFA setup flow."
}

variable "extension_client_id" {
  type        = string
  description = "Client ID of the browser extension's public OAuth (PKCE) app client, surfaced through config.js."
}

variable "user_pool_domain" {
  type        = string
  description = "Hosted-UI domain prefix of the Cognito user pool (without the .auth.<region>.amazoncognito.com suffix), surfaced through config.js for the browser extension's Hosted UI flow."
}

variable "region" {
  type        = string
  description = "The AWS region."
}

variable "control_domain" {
  type        = string
  description = "The control domain."
}

variable "relay_ips" {
  type        = list(string)
  description = "Egress IP addresses."
}

variable "cert_arn" {
  type        = string
  description = "ARN for the AWS Certificate Manager certificate for the control domain."
}

variable "zone_id" {
  type        = string
  description = "Route 53 zone ID for the control domain."
}

variable "private_zone_id" {
  type        = string
  description = "Route 53 private zone ID for the control domain. The admin CNAME is mirrored here so VPC-internal callers (e.g. Kuma) can resolve admin.<control-domain>."
}

variable "domains" {
  type        = list(any)
  description = "List of email domains."
}

variable "dev_mode" {
  type        = bool
  description = "If true, forces Cloudfront to non-caching configuration."
}

variable "stage_name" {
  type        = string
  default     = "prod"
  description = "Name for the API Gateway stage. Default: prod."
}

variable "bucket" {
  type        = string
  description = "Name of s3 bucket"
}

variable "bucket_domain_name" {
  type        = string
  description = "Regional domain name of the s3 bucket (OAC sigv4 signing requires the regional endpoint)."
}

variable "bucket_arn" {
  type        = string
  description = "ARN of the admin app s3 bucket, granted to CloudFront in the bucket policy."
}

variable "oai_iam_arn" {
  type        = string
  description = "IAM ARN of the legacy CloudFront origin access identity. Transitional: its bucket-policy grant keeps the distribution serving while the OAC config propagates; removed once the OAC cutover is verified."
}

variable "address_changed_topic_arn" {
  type        = string
  description = "ARN of the SNS topic for address change notifications to ECS containers."
}

variable "user_rules_topic_arn" {
  type        = string
  description = "ARN of the SNS topic for user-mail-rules change notifications to the imap tier."
}

variable "dmarc_healthcheck_ping_param" {
  type        = string
  description = "SSM Parameter Store name holding the Healthchecks ping URL for the process_dmarc Lambda. Empty string disables the heartbeat."
  default     = ""
}

variable "dmarc_report_senders" {
  type        = string
  description = "Comma-separated allowlist of From: domains the process_dmarc Lambda will parse reports from. Subdomains of an entry are also accepted. Empty disables sender filtering."
  default     = "google.com,microsoft.com,yahoo-inc.com,fastmail.com,protonmail.com,mailchimp.com,emarsys.net"
}

variable "dmarc_max_payload_bytes" {
  type        = number
  description = "Ceiling on the decompressed size of a single DMARC attachment, in bytes. Defeats zip/gzip bombs in the process_dmarc Lambda."
  default     = 52428800 # 50 MiB
}

variable "dmarc_max_messages_per_run" {
  type        = number
  description = "Maximum INBOX messages the process_dmarc Lambda examines per scheduled run. The handler is idempotent, so a backlog drains over successive runs."
  default     = 50
}

variable "invitation_required" {
  type        = bool
  description = "When true, the React signup form renders the invitation-code field and requires a non-empty value. Plumbed into /config.js so the client can mirror the server-side check_invite gate."
  default     = false
}

variable "sms_enabled" {
  type        = bool
  description = "Mirror of the user_pool module's sms_enabled output (true iff a 10DLC campaign registration id is configured). Plumbed into /config.js so the React signup form can hide the phone-number field and consent checkbox when the pool is not wired for SMS. See docs/sms-10dlc.md and issue #712."
  default     = false
}

variable "monitoring" {
  type        = bool
  description = "Mirror of the top-level var.monitoring. When true, /config.js advertises the monitoring stack so the admin app's Nav can surface Uptime Kuma, Healthchecks, and Grafana entries (which target uptime/heartbeat/metrics.<control-domain>)."
  default     = false
}

variable "imap_pool_enabled" {
  type        = bool
  description = "Mirror of the top-level var.imap_pool_enabled. Reuse authenticated IMAP sessions across warm Lambda invocations (large-mailbox hardening plan, Layer 1.5). Off by default; enable per-environment once validated."
  default     = false
}

variable "access_logs_bucket" {
  type        = string
  description = "Name of the shared S3 server-access-log target bucket (modules/s3_access_logs) the cache bucket's access logs are delivered to."
}

variable "push_queue_arn" {
  type        = string
  description = "ARN of the push wake-signal SQS queue (modules/ecs). Event source for the push_dispatch Lambda."
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC the API Lambdas attach to (private-IMAP replumb). Owns the Lambda security group."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs the API Lambdas attach to. Egress to AWS APIs and the internet rides the NAT path plus the S3/DynamoDB gateway endpoints."
}

variable "imap_internal_host" {
  type        = string
  description = "Cloud Map DNS name of the imap task (modules/ecs service discovery). IMAP-consuming Lambdas dial this on 143 + STARTTLS instead of the public IMAPS listener."
}

variable "smtp_internal_host" {
  type        = string
  description = "Cloud Map DNS name of the smtp-out task (modules/ecs service discovery). The send Lambda dials it on 465 instead of the public submission listener, falling back to the public path if the name does not resolve."
}

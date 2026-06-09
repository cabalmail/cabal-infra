variable "environment" {
  type        = string
  description = "A name for your environment such as 'production' or 'staging'."
}

variable "aws_region" {
  type        = string
  description = "AWS region in which to provision primary infrastructure. Default us-west-1."
  default     = "us-west-1"
  validation {
    condition     = can(regex("^[[:alpha:]]{2}-(central|(north|south)?(east|west))-[[:digit:]]$", var.aws_region))
    error_message = "The aws_region does not appear to be a valid AWS region string."
  }
}

variable "prod" {
  type        = bool
  description = "Whether to use the production Let's Encrypt service. Default false."
  default     = false
}

variable "email" {
  type        = string
  description = "Email for the CSR."
}

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones to use for the primary region."
  default = [
    "us-west-1a"
  ]
  validation {
    condition = alltrue([
      for str in var.availability_zones : can(regex("^[[:alpha:]]{2}-(central|(north|south)?(east|west))-[[:digit:]][[:alpha:]]$", str))
    ])
    error_message = "One or more of the availability_zones do not appear to be valid AWS availability strings."
  }
}

variable "cidr_block" {
  type        = string
  description = "CIDR block for the VPC in the primary region."
  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "The cidr_block does not appear to be a valid CIDR."
  }
}

variable "repo" {
  type        = string
  description = "This repository. Used for resource tagging."
  default     = "https://github.com/ccarr-cabal/cabal-infra/tree/main"
}

variable "control_domain" {
  type        = string
  description = "The domain used for naming your email infrastructure. E.g., if you want to host imap.example.com and smtp-out.example.com, then this would be 'example.com'. It may also be listed in mail_domains to host email addresses on its subdomains, in which case its bootstrap zone is reused rather than duplicated; its apex is never addressable."
  validation {
    condition     = can(regex("^(([[:alpha:]]|-|_|[[:digit:]])+\\.)+[[:alpha:]]+$", var.control_domain))
    error_message = "The control_domain does not appear to be a valid domain name."
  }
}

variable "mail_domains" {
  type        = list(string)
  description = "List of domains from which you want to send mail, and to which you want to allow mail to be sent. Must have at least one."
  validation {
    condition = alltrue([
      for str in var.mail_domains : can(regex("^(([[:alpha:]]|-|_|[[:digit:]])+\\.)+[[:alpha:]]+$", str))
    ])
    error_message = "One or more of the mail_domains does not appear to be a valid domain name."
  }
  validation {
    condition     = length(var.mail_domains) > 0
    error_message = "You must have at least one mail_domain."
  }
}

variable "backup" {
  type        = bool
  description = "Whether to create backups of critical data. Defaults to the prod setting. Defaults to false."
  default     = false
}

variable "monitoring" {
  type        = bool
  description = "Whether to deploy the monitoring & alerting stack (Uptime Kuma, self-hosted ntfy, alert_sink Lambda). Defaults to false."
  default     = false
  validation {
    condition     = !var.monitoring || length(var.availability_zones) >= 2
    error_message = "var.monitoring requires at least two availability_zones. The monitoring stack provisions a public ALB, which AWS requires to span >= 2 AZs. See docs/monitoring.md."
  }
}

# Feature flag for the SMTP sinkhole test fixture. See
# docs/0.9.x/sinkhole-test-harness-plan.md. The ECR repo is created
# regardless so images can be pre-built; only the ECS tier (task def,
# service, Cloud Map, SSM parameter) and the smtp-out mailertable line
# are gated on this flag. The sinkhole task definition carries a
# precondition that refuses to plan when var.environment == "prod",
# so an accidental TF_VAR_SINKHOLE=true on prod fails at plan time.
variable "sinkhole" {
  type        = bool
  description = "Whether to deploy the SMTP sinkhole test fixture (tiny configurable SMTP listener used to produce on-demand deferred-retry responses for queue-persistence and DSN testing). Permanent in dev and stage; refused in prod by a Terraform precondition. Defaults to false."
  default     = false
  validation {
    condition     = !(var.sinkhole && var.environment == "prod")
    error_message = "var.sinkhole must never be true in prod. See docs/0.9.x/sinkhole-test-harness-plan.md."
  }
}

variable "healthchecks_registration_open" {
  type        = bool
  description = "Whether the Healthchecks signup form is open. Set to true at bootstrap so the operator can sign up the first user via the magic-link flow, then flip back to false. Has no effect when var.monitoring is false (no Healthchecks task is deployed)."
  default     = false
}

variable "quiesced" {
  type        = bool
  description = "When true, scale all running compute (ECS service desired counts, the ECS-instance ASG, and NAT instances) to zero to save cost. State-bearing resources (DynamoDB, EFS, S3, Cognito, Route 53, ACM, NLB) are unaffected. Intended for non-prod environments only; the quiesce workflow refuses to run against prod."
  default     = false
}

variable "use_custom_nat_ami" {
  type        = bool
  description = "When true, NAT instances launch from the EC2 Image Builder-baked AL2023 AMI (nftables pre-installed) instead of the stock Amazon Linux 2 AMI. Leave false until the Image Builder pipeline has produced at least one AMI (the data.aws_ami lookup hard-errors on an empty result). Also doubles as a rollback lever: set back to false to return to the stock AL2 NAT bootstrap."
  default     = false
}

# Populated by .github/scripts/record-lambda-hashes.sh at CI time and
# fed into terraform plan/apply as -var-file=.terraform/lambda-pinned.tfvars.
# See phase 2 of docs/0.9.x/build-deploy-simplification-plan.md. Reserved
# for phase 3 wiring; not consumed by Lambda resources yet, so the
# default {} keeps local plans (and the steady-state CI flow) working.
# tflint-ignore: terraform_unused_declarations # reserved for phase-3 Lambda-deploy wiring (see comment above); intentionally unused for now
variable "lambda_pinned_hashes" {
  type        = map(string)
  description = "Map of Lambda function name to currently-deployed CodeSha256, recorded from AWS at CI time so a topology-only Terraform apply can plan against running code identities once phase 3 introduces out-of-band Lambda deploys."
  default     = {}
}

variable "use_eum_sms" {
  type        = bool
  description = "Feature flag: when true, provision the AWS End User Messaging toll-free phone number for Cognito SMS via SNS. When false, the EUM phone number is not created and Cognito's sms_configuration block falls through to the shared AWS SMS pool (which is sandboxed without registration)."
  default     = false
}

variable "invitation_code" {
  type        = string
  description = "Shared secret that new users must supply on the signup form. Surfaced to the check_invite pre-signup Lambda as the INVITATION_CODE env var. Empty string disables the check and allows all signups."
  sensitive   = true
  default     = ""
}

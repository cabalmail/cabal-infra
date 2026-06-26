variable "name" {
  type = string
}

variable "runtime" {
  type = string
}

variable "gateway_id" {
  type = string
}

variable "root_resource_id" {
  type = string
}

variable "region" {
  type = string
}

variable "method" {
  type = string
}

variable "account" {
  type = string
}

variable "authorizer" {
  type = string
}

variable "control_domain" {
  type = string
}

variable "domains" {
  type = list(any)
}

variable "bucket" {
  type = string
}

variable "memory" {
  type    = number
  default = 128
}

variable "address_changed_topic_arn" {
  type        = string
  description = "ARN of the SNS topic for address change notifications to ECS containers."
}

variable "user_pool_id" {
  type        = string
  description = "ID of the Cognito user pool."
}

variable "alarm_on_latency" {
  type        = bool
  default     = false
  description = "Wire CloudWatch alarms on tail latency and errors for this endpoint. Set for the message-list endpoints whose latency tracks folder cardinality (large-mailbox hardening plan, Layer 4.3)."
}

variable "imap_pool_enabled" {
  type        = bool
  default     = false
  description = "Reuse authenticated IMAP sessions across warm invocations of this Lambda (large-mailbox hardening plan, Layer 1.5). Off by default; enable per-environment once validated."
}

variable "architecture" {
  type        = string
  default     = "arm64"
  description = "Lambda instruction set. The fleet is arm64; fetch_bimi overrides to x86_64 because its bundled resvg rasterizer has no prebuilt linux-aarch64 binary (see docs/0.9.x/bimi.md)."

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}
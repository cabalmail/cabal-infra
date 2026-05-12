variable "bucket" {
  type        = string
  description = "S3 bucket for Lambda function code"
}

variable "twilio_account_sid" {
  type        = string
  description = "Twilio Account SID"
  sensitive   = true
}

variable "twilio_api_key" {
  type        = string
  description = "Twilio API key"
  sensitive   = true
}

variable "twilio_api_secret" {
  type        = string
  description = "Twilio API secret"
  sensitive   = true
}

variable "twilio_from_number" {
  type        = string
  description = "Twilio phone number to send SMS from"
}

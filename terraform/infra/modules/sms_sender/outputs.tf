output "lambda_arn" {
  value       = aws_lambda_function.sms_sender.arn
  description = "ARN of the sms-sender Lambda function"
}

output "kms_key_arn" {
  value       = aws_kms_key.sms_sender.arn
  description = "ARN of the KMS key for SMS sender"
}

output "kms_key_id" {
  value       = aws_kms_key.sms_sender.id
  description = "ID of the KMS key for SMS sender"
}

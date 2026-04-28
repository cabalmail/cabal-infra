output "table_arn" {
  value       = aws_dynamodb_table.addresses.arn
  description = "ARN of DynamoDB table."
}

output "user_preferences_table_arn" {
  value       = aws_dynamodb_table.user_preferences.arn
  description = "ARN of the user preferences DynamoDB table."
}
output "table_arn" {
  value       = aws_dynamodb_table.addresses.arn
  description = "ARN of DynamoDB table."
}
output "table_arn" {
  value       = aws_dynamodb_table.addresses.arn
  description = "ARN of DynamoDB table."
}

output "user_preferences_table_arn" {
  value       = aws_dynamodb_table.user_preferences.arn
  description = "ARN of the user preferences DynamoDB table."
}

output "user_rules_table_arn" {
  value       = aws_dynamodb_table.user_rules.arn
  description = "ARN of the user mail-rules DynamoDB table."
}

output "rss_table_arns" {
  value = [
    aws_dynamodb_table.rss_feed.arn,
    aws_dynamodb_table.rss_item.arn,
    aws_dynamodb_table.rss_subscription.arn,
    aws_dynamodb_table.rss_folder.arn,
    aws_dynamodb_table.rss_user_item_state.arn,
  ]
  description = "ARNs of the five RSS reader tables (docs/1.x/rss-implementation-plan.md), for the backup selection and, from phase 2, the RSS Lambdas' IAM grants."
}

output "rss_item_stream_arn" {
  value       = aws_dynamodb_table.rss_item.stream_arn
  description = "Stream ARN of cabal-rss-item; the rss_notify Lambda's event source (phase 8)."
}

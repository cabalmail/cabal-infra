output "master_password" {
  value = random_password.password.result
}


output "cloudfront_distribution_arn" {
  value       = aws_cloudfront_distribution.cdn.arn
  description = "ARN of the admin app CloudFront distribution. Used as the access-log delivery source (modules/cloudfront_logs)."
}

output "mcp_url" {
  value       = local.mcp_oauth.resource_url
  description = "URL of the read-only MCP server (POST /mcp). The MCP server URL to enter when adding Cabalmail as a claude.ai custom connector."
}

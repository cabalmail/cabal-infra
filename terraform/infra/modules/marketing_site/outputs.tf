output "bucket" {
  value       = aws_s3_bucket.this.id
  description = "Name of the S3 bucket backing the marketing site."
}

output "cloudfront_distribution_id" {
  value       = aws_cloudfront_distribution.this.id
  description = "CloudFront distribution ID for the marketing site. Use this for cache invalidation when the site is updated out-of-band."
}

output "site_url" {
  value       = "https://${local.site_host}/"
  description = "Public URL of the marketing site."
}

output "privacy_url" {
  value       = "https://${local.site_host}/privacy.html"
  description = "Public URL of the privacy policy page. Use this as the privacy policy URL on carrier registrations (AWS End User Messaging TFV, Twilio A2P 10DLC)."
}

output "terms_url" {
  value       = "https://${local.site_host}/terms.html"
  description = "Public URL of the terms of service page."
}

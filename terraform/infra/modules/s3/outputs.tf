output "bucket_arn" {
  value = local.bucket_arn
}

output "bucket" {
  value = aws_s3_bucket.this.id
}

# Regional endpoint: OAC sigv4 signing requires the regional domain
# name (the global endpoint can redirect outside us-east-1, which
# breaks the signature).
output "domain_name" {
  value = aws_s3_bucket.this.bucket_regional_domain_name
}

# Transitional: consumed by the app module's bucket policy for the
# legacy OAI grant until the OAC cutover is verified; see the OAI
# resource comment in main.tf for the removal order.
output "oai_iam_arn" {
  value = aws_cloudfront_origin_access_identity.origin.iam_arn
}

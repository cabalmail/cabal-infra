output "bucket_arn" {
  value = local.bucket_arn
}

output "bucket" {
  value = local.bucket
}

output "origin" {
  value = aws_cloudfront_origin_access_identity.origin.id
}
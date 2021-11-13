resource "aws_s3_bucket" "cabal_image_builder_log_bucket" {
  acl           = "private"
  bucket_prefix = "cabal-logs-"
}
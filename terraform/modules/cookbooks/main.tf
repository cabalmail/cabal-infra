resource "aws_s3_bucket" "cabal_cookbook_bucket" {
  acl           = "private"
  bucket_prefix = "cabal-artifacts-"
}

resource "aws_s3_bucket_object" "cabal_cookbook_files" {
  for_each = fileset(path.module, "objects/**/*")

  bucket   = aws_s3_bucket.cabal_cookbook_bucket.bucket
  key      = each.value
  source   = "${path.module}/${each.value}"
  etag     = filemd5("${path.module}/${each.value}")
}
resource "aws_s3_bucket" "cabal_cookbook_bucket" {
  acl           = "private"
  bucket_prefix = "cabal-artifacts-"
}

data "archive_file" "cabal_cookbook_archive" {
  type        = "zip"
  source_dir  = "${path.module}/../../../chef/cabal"
  output_path = "${path.module}/cabal_cookbook.zip"
}

resource "aws_s3_bucket_object" "cabal_cookbook_object" {
  bucket   = aws_s3_bucket.cabal_cookbook_bucket.bucket
  key      = "/cabal.zip"
  source   = "${path.module}/cabal_cookbook.zip"
}

# resource "aws_s3_bucket_object" "cabal_cookbook_files" {
#   for_each = fileset(path.module, "../../../chef/cabal/**/*")

#   bucket   = aws_s3_bucket.cabal_cookbook_bucket.bucket
#   key      = each.value
#   source   = "${path.module}/${each.value}"
#   etag     = filemd5("${path.module}/${each.value}")
# }
resource "aws_s3_bucket" "cabal_cookbook_bucket" {
  acl           = "private"
  bucket_prefix = "cabal-artifacts-"
}

data "archive_file" "cabal_cookbook_archive" {
  type        = "zip"
  source_dir  = "${path.module}/../../../chef/"
  output_path = "${path.module}/cabal_cookbook.zip"
}

resource "aws_s3_bucket_object" "cabal_cookbook_object" {
  bucket   = aws_s3_bucket.cabal_cookbook_bucket.bucket
  key      = "/cabal.zip"
  source   = data.archive_file.cabal_cookbook_archive.output_path
  etag     = filemd5(data.archive_file.cabal_cookbook_archive.output_path)
}
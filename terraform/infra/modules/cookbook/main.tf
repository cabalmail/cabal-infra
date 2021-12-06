/**
* Zips the content of the /chef directory (the cabal cookbook) and stores it in an S3 bucket for retrieval by servers at boot time (by operation of the userdata script).
*/

resource "aws_s3_bucket" "cookbook" {
  acl           = "private"
  bucket_prefix = "cabal-artifacts-"
}

data "archive_file" "cookbook" {
  type        = "zip"
  source_dir  = "${path.module}/../../../../chef/"
  output_path = "${path.module}/cabal_cookbook.zip"
}

resource "aws_s3_bucket_object" "cookbook" {
  bucket   = aws_s3_bucket.cookbook.bucket
  key      = "/cabal.zip"
  source   = data.archive_file.cookbook.output_path
  etag     = filemd5(data.archive_file.cookbook.output_path)
}
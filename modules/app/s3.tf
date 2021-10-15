resource "aws_s3_bucket" "cabal_website_bucket" {
  acl    = "public-read"
  bucket = "admin.${var.control_domain}"
  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}

resource "aws_s3_bucket_policy" "cabal_website_bucket_policy" {
  bucket = aws_s3_bucket.cabal_website_bucket.id
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
        {
          "Sid": "Viscious",
          "Effect": "Allow",
          "Principal": {
            "AWS": aws_cloudfront_origin_access_identity.cabal_s3_origin.iam_arn
          },
          "Action": "s3:GetObject",
          "Resource": "arn:aws:s3:::admin.${var.control_domain}/*"
        }
    ]
  })
}

resource "aws_s3_bucket_object" "cabal_website_files" {
  for_each     = fileset("${path.module}/objects", "**/*")
  bucket       = aws_s3_bucket.cabal_website_bucket.bucket
  key          = each.value
  content_type = length(regexall("\\.html$", each.value)) > 0 ? "text/html" : (
                   length(regexall("\\.css$", each.value)) > 0 ? "text/css" : (
                     length(regexall("\\.png$", each.value)) > 0 ? "image/png" : (
                       length(regexall("\\.js$", each.value)) > 0 ? "text/javascript" : (
                         "application/octet-stream"
                       )
                     )
                   )
                 )
  source       = "${path.module}/objects/${each.value}"
  etag         = filemd5("${path.module}/objects/${each.value}")
}

resource "aws_s3_bucket_object" "cabal_website_templates" {
  for_each     = fileset("${path.module}/templates", "**/*")
  bucket       = aws_s3_bucket.cabal_website_bucket.bucket
  key          = each.value
  content_type = "text/javascript"
  content      = templatefile("${path.module}/templates/${each.value}", {
    pool_id        = var.user_pool_id,
    pool_client_id = var.user_pool_client_id,
    region         = var.region,
    invoke_url     = aws_api_gateway_stage.cabal_api_deployment.invoke_url
    domains        = {for domain in var.domains : domain.domain => domain.zone_id}
  })
  etag         = md5(templatefile("${path.module}/templates/${each.value}", {
      pool_id        = var.user_pool_id,
      pool_client_id = var.user_pool_client_id,
      region         = var.region,
      invoke_url     = aws_api_gateway_stage.cabal_api_deployment.invoke_url
      domains        = {for domain in var.domains : domain.domain => domain.zone_id}
    })
  )
}
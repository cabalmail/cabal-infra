# TODO:
# CloudFront for static website
# Lambdas
# API Gateway

resource "aws_api_gateway_rest_api" "cabal_gateway" {
  name = "cabal_gateway"
}

module "cabal_list_method" {
  source           = "./modules/call"
  name             = "list"
  runtime          = "nodejs6.10"
  gateway_id       = aws_api_gateway_rest_api.cabal_gateway.id
  root_resource_id = aws_api_gateway_rest_api.cabal_gateway.root_resource_id
}

module "cabal_request_method" {
  source           = "./modules/call"
  name             = "request"
  runtime          = "nodejs6.10"
  gateway_id       = aws_api_gateway_rest_api.cabal_gateway.id
  root_resource_id = aws_api_gateway_rest_api.cabal_gateway.root_resource_id
}

module "cabal_revoke_method" {
  source           = "./modules/call"
  name             = "revoke"
  runtime          = "nodejs6.10"
  gateway_id       = aws_api_gateway_rest_api.cabal_gateway.id
  root_resource_id = aws_api_gateway_rest_api.cabal_gateway.root_resource_id
}

resource "aws_s3_bucket" "cabal_website_bucket" {
  acl           = "private"
  bucket_prefix = "cabal-website-"
}

resource "aws_s3_bucket_object" "cabal_website_files" {
  for_each = fileset(path.module, "objects/**/*")

  bucket   = aws_s3_bucket.cabal_website_bucket.bucket
  key      = each.value
  source   = "${path.module}/${each.value}"
  etag     = filemd5("${path.module}/${each.value}")
}

resource "aws_s3_bucket_object" "cabal_website_templates" {
  for_each = fileset(path.module, "templates/**/*")

  bucket   = aws_s3_bucket.cabal_website_bucket.bucket
  key      = each.value
  content  = templatefile("${path.module}/${each.value}", {
    pool_id        = var.user_pool_id,
    pool_client_id = var.user_pool_client_id,
    region         = var.region,
    invoke_url     = "http://example.com/"
  })
  etag     = md5(templatefile("${path.module}/${each.value}", {
      pool_id        = var.user_pool_id,
      pool_client_id = var.user_pool_client_id,
      region         = var.region,
      invoke_url     = "http://example.com/"
    })
  )
}

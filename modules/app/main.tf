# TODO:
# CloudFront for static website
# Lambdas
# API Gateway

resource "aws_api_gateway_rest_api" "cabal_gateway" {
  name = "cabal_gateway"
}

resource "aws_api_gateway_resource" "cabal_resource" {
  rest_api_id = "${aws_api_gateway_rest_api.cabal_gateway.id}"
  parent_id   = "${aws_api_gateway_rest_api.cabal_gateway.root_resource_id}"
  path_part   = "{proxy+}"
}
resource "aws_api_gateway_method" "cabal_method" {
  rest_api_id   = "${aws_api_gateway_rest_api.cabal_gateway.id}"
  resource_id   = "${aws_api_gateway_resource.cabal_resource.id}"
  http_method   = "ANY"
  authorization = "NONE"
  request_parameters = {
    "method.request.path.proxy" = true
  }
}
resource "aws_api_gateway_integration" "cabal_integration" {
  rest_api_id = "${aws_api_gateway_rest_api.cabal_gateway.id}"
  resource_id = "${aws_api_gateway_resource.cabal_resource.id}"
  http_method = "${aws_api_gateway_method.cabal_method.http_method}"
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://your.domain.com/{proxy}"
 
  request_parameters =  {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
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
  source   = "${path.module}/${each.value}"
  etag     = md5(templatefile("${path.module}/${each.value}", {
      pool_id        = var.user_pool_id,
      pool_client_id = var.user_pool_client_id,
      region         = var.region,
      invoke_url     = "http://example.com/"
    })
  )
}

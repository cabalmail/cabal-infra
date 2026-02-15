locals {
  supported_lambda_layers = {
    python = {
      runtime = "python3.9"
    },
    nodejs = {
      runtime = "nodejs14.x"
    }
  }
}

data "aws_s3_objects" "check" {
  for_each = local.supported_lambda_layers
  bucket   = var.bucket
  prefix   = "lambda/${each.key}.zip.base64sha256"
}

locals {
  lambda_layers = {
    for l in keys(local.supported_lambda_layers) :
      l => local.supported_lambda_layers[l]
      if length(data.aws_s3_objects.check[l].keys) > 0
  }
}

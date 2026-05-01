/**
* Creates a Lambda layer for use by other modules.
* Zip files are built with Github actions; see
* [app.yml](/.github/workflows/app.yml) (the `lambda-api` job).
*/

# Get previously computed hash for zip file.
data "aws_s3_object" "lambda_layer_hash" {
  for_each = local.lambda_layers
  bucket   = var.bucket
  key      = "/lambda/${each.key}.zip.base64sha256"
}

# Create Lambda layer from previously created zip file.
resource "aws_lambda_layer_version" "layer" {
  for_each            = local.lambda_layers
  layer_name          = each.key
  compatible_runtimes = [each.value.runtime]
  s3_bucket           = var.bucket
  s3_key              = "lambda/${each.key}.zip"
  source_code_hash    = data.aws_s3_object.lambda_layer_hash[each.key].body
}
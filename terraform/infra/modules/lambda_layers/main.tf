resource "aws_lambda_layer_version" "layer" {
  for_each            = local.lambda_layers
  layer_name          = each.key
  compatible_runtimes = [each.value.runtime]
  s3_bucket           = var.bucket
  s3_key              = "lambda/${each.key}.zip"
  source_code_hash    = data.aws_s3_object.lambda_layer_hash[each.key].body
}
output "layers" {
  value = [for k, v in aws_lambda_layer_version.layer : k => v.arn ]
}
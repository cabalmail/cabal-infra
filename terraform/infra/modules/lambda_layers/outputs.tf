output "layers" {
  value = aws_lambda_layer_version.layer[*].arn
}
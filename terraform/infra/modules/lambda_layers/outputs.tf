output "layers" {
  value = {
    "nodejs" = aws_lambda_layer_version.layer["nodejs"].arn,
    "python" = aws_lambda_layer_version.layer["python"].arn
  }
}
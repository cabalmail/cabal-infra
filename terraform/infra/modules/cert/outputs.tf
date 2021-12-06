output "cert_arn" {
  value       = aws_acm_certificate.cert.arn
  description = "ARN of the AWS Certificate Manager certificate."
}
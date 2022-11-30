output "control_domain_name_servers" {
  value = aws_route53_zone.cabal_control_zone.name_servers
}

output "aws_s3_bucket" {
  value = "admin.${var.control_domain}"
}

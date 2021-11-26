resource "aws_route53_zone" "private_dns" {
  name    = var.control_domain
  comment = "Internal control domain"
  vpc {
    vpc_id = aws_vpc.network.id
  }
}
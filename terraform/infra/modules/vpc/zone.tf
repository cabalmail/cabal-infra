resource "aws_route53_zone" "cabal_private_control_zone" {
  name    = var.control_domain
  comment = "Internal control domain"
  vpc {
    vpc_id = aws_vpc.cabal_vpc.id
  }
}
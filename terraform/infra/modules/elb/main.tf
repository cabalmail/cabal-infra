resource "aws_lb" "elb" {
  name                             = "cabal-nlb"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = var.public_subnets[*].id
  enable_cross_zone_load_balancing = false
  tags                             = {
    Name = "cabal-nlb"
  }
}
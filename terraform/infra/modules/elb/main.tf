/**
* Creates a network load balancer that is shared by all three tiers, target groups, listeners, and DNS.
*/

resource "aws_lb" "elb" {
  name                             = "cabal-nlb"
  internal                         = false #tfsec:ignore:aws-elb-alb-not-public
  load_balancer_type               = "network"
  subnets                          = var.public_subnet_ids
  enable_cross_zone_load_balancing = true
  tags = {
    Name = "cabal-nlb"
  }
}
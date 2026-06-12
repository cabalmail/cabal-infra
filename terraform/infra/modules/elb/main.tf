/**
* Creates a network load balancer that is shared by all three tiers, target groups, listeners, and DNS.
*/

resource "aws_lb" "elb" {
  name                             = "cabal-nlb"
  internal                         = false #tfsec:ignore:aws-elb-alb-not-public
  load_balancer_type               = "network"
  subnets                          = var.public_subnet_ids
  enable_cross_zone_load_balancing = true

  # TLS-listener connections only (the IMAPS listener; SMTP is TCP
  # passthrough and never appears here) - see access_logs.tf for the
  # caveat and the bucket.
  access_logs {
    bucket  = aws_s3_bucket.nlb_access_logs.id
    enabled = true
    prefix  = "mail-nlb"
  }

  # The bucket policy must exist before ELB validates delivery
  # permissions at modify-load-balancer-attributes time; the implicit
  # reference above only orders against the bucket itself.
  depends_on = [aws_s3_bucket_policy.nlb_access_logs]

  tags = {
    Name = "cabal-nlb"
  }
}
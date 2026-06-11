resource "aws_lb_listener" "imap" {
  load_balancer_arn = aws_lb.elb.arn
  protocol          = "TLS"
  port              = "993"
  certificate_arn   = var.cert_arn
  # Pin TLS 1.2/1.3 with strong ciphers. Without ssl_policy an NLB TLS
  # listener defaults to ELBSecurityPolicy-2016-08, which still permits TLS
  # 1.0/1.1 - this is the client-facing IMAPS endpoint (CKV_AWS_103/CKV2_AWS_74).
  ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = var.ecs_imap_target_group_arn
  }
}

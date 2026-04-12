resource "aws_lb_listener" "imap" {
  load_balancer_arn = aws_lb.elb.arn
  protocol          = "TLS"
  port              = "993"
  certificate_arn   = var.cert_arn
  default_action {
    type             = "forward"
    target_group_arn = var.ecs_imap_target_group_arn
  }
}

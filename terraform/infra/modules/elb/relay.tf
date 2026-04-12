resource "aws_lb_listener" "relay" {
  load_balancer_arn = aws_lb.elb.arn
  protocol          = "TCP"
  port              = "25"
  default_action {
    type             = "forward"
    target_group_arn = var.ecs_relay_target_group_arn
  }
}

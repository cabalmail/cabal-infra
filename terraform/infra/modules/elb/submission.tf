resource "aws_lb_listener" "submission" {
  load_balancer_arn = aws_lb.elb.arn
  protocol          = "TCP"
  port              = "465"
  default_action {
    type             = "forward"
    target_group_arn = var.ecs_submission_target_group_arn
  }
}

resource "aws_lb_listener" "starttls" {
  load_balancer_arn = aws_lb.elb.arn
  protocol          = "TCP"
  port              = "587"
  default_action {
    type             = "forward"
    target_group_arn = var.ecs_starttls_target_group_arn
  }
}

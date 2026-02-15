output "nlb_arn" {
  value       = aws_lb.elb.arn
  description = "ARN of the network load balancer."
}

output "imap_tg" {
  value       = aws_lb_target_group.imap.arn
  description = "ARN of IMAP target group."
}

output "submission_tg" {
  value       = aws_lb_target_group.submission.arn
  description = "ARN of SMTP submission target group."
}

output "starttls_tg" {
  value       = aws_lb_target_group.starttls.arn
  description = "ARN of SMTP StartTLS target group."
}

output "relay_tg" {
  value       = aws_lb_target_group.relay.arn
  description = "ARN of SMTP relay target group."
}
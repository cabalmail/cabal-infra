output "nlb_arn" {
  value       = aws_lb.elb.arn
  description = "ARN of the network load balancer."
}

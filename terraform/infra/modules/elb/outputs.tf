output "imap_tg" {
  value = aws_lb_target_group.imap.arn
}

output "submission_tg" {
  value = aws_lb_target_group.submission.arn
}

output "starttls_tg" {
  value = aws_lb_target_group.starttls.arn
}

output "relay_tg" {
  value = aws_lb_target_group.relay.arn
}
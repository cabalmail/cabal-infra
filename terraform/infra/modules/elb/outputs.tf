output "imap_tg" {
  value = aws_lb_target_group.cabal_imap_tg.arn
}

output "submission_tg" {
  value = aws_lb_target_group.cabal_smtp_submission_tg.arn
}

output "starttls_tg" {
  value = aws_lb_target_group.cabal_smtp_starttls_tg.arn
}

output "relay_tg" {
  value = aws_lb_target_group.cabal_smtp_relay_tg.arn
}
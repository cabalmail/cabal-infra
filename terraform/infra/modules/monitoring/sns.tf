# ── SNS alerts topic ───────────────────────────────────────────
#
# Independent of cabal-address-changed (ECS reconfigure) and of the
# Cognito verification path in 0.5.0.

resource "aws_sns_topic" "alerts" {
  name              = "cabal-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "sms" {
  for_each  = toset(var.on_call_phone_numbers)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "sms"
  endpoint  = each.value
}

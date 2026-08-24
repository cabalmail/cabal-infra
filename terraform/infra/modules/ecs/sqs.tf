/**
* SQS queues for the reconfiguration sidecar (one per tier).
*
* Each queue subscribes to the cabal-address-changed SNS topic. The
* reconfigure.sh sidecar in each container long-polls its queue and
* regenerates sendmail maps when a message arrives.
*/

resource "aws_sqs_queue" "tier" {
  for_each                   = local.tiers
  name                       = "cabal-reconfig-${each.key}"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 3600
  # SSE-SQS (SQS-owned key): encrypts at rest with no KMS key to manage and
  # no key-policy/IAM changes. SNS->SQS delivery and the reconfigure sidecar
  # consumers are transparent to it (unlike SSE-KMS, which would need perms).
  sqs_managed_sse_enabled = true
}

resource "aws_sqs_queue_policy" "tier" {
  for_each  = local.tiers
  queue_url = aws_sqs_queue.tier[each.key].url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.tier[each.key].arn
      Condition = {
        # The imap queue also receives user-mail-rules notifications
        # (aws_sns_topic_subscription.imap_user_rules below); ArnEquals
        # with a list ORs the allowed source topics.
        ArnEquals = {
          "aws:SourceArn" = each.key == "imap" ? [
            aws_sns_topic.address_changed.arn,
            aws_sns_topic.user_rules_changed.arn,
          ] : [aws_sns_topic.address_changed.arn]
        }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "tier" {
  for_each  = local.tiers
  topic_arn = aws_sns_topic.address_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.tier[each.key].arn
}

# The imap tier additionally regenerates per-user procmail rule files
# (docs/1.x/user-mail-rules-plan.md), so its queue fans in the user-rules
# topic on top of the address topic. reconfigure.sh treats any queue
# message as a regenerate trigger.
resource "aws_sns_topic_subscription" "imap_user_rules" {
  topic_arn = aws_sns_topic.user_rules_changed.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.tier["imap"].arn
}

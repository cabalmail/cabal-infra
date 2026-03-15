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
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.address_changed.arn }
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

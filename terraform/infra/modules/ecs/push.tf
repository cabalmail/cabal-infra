/**
* Push-notification wake-signal queue (docs/0.11.0/push-notifications.md).
*
* The imap container's procmail recipe enqueues one small JSON message per
* local delivery via docker/shared/push-enqueue.sh (best-effort: a failed
* enqueue never blocks or fails mail delivery). The push_dispatch Lambda in
* the app module consumes the queue and fans out to APNs. The queue lives
* here, next to the producer's task role and task definition, mirroring the
* reconfigure queues; the consumer side (Lambda, event source mapping, APNs
* SSM parameters) lives in modules/app/push_dispatch.tf.
*/

resource "aws_sqs_queue" "push_dlq" {
  name                      = "cabal-push-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "push" {
  name = "cabal-push-queue"
  # >= the dispatch Lambda's 60s function timeout (same rule as append_sent).
  visibility_timeout_seconds = 120
  # A push older than an hour is noise, not news: the user's device would
  # show a stale "New mail" long after the fact. Let undeliverable signals
  # age out instead of retrying into irrelevance.
  message_retention_seconds = 3600

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.push_dlq.arn
    maxReceiveCount     = 5
  })
}

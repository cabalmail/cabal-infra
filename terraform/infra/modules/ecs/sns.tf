/**
* SNS topic for address-change fan-out.
*
* When the new/revoke Lambdas update the cabal-addresses DynamoDB table,
* they publish to this topic. Each SQS queue (one per tier) receives the
* notification and the reconfigure sidecar in each container picks it up.
*/

resource "aws_sns_topic" "address_changed" {
  name = "cabal-address-changed"
  # SSE with the AWS-managed SNS key (free). SNS has no SQS-style managed-SSE
  # option, so this needs a KMS key. The new/revoke Lambda (the only publisher)
  # is granted kms:GenerateDataKey/Decrypt scoped via kms:ViaService=sns in
  # its role (modules/app/modules/call/lambda.tf), so publish keeps working.
  kms_master_key_id = "alias/aws/sns"
}

/**
* SNS topic for user-mail-rules fan-out (docs/1.x/user-mail-rules-plan.md).
*
* The set_rules Lambda publishes here on every successful rule-set write;
* only the imap tier's queue subscribes (sqs.tf). A separate topic rather
* than piggybacking on cabal-address-changed because rule writes happen at
* debounced-typing cadence and the address topic implies a full DynamoDB
* scan + sendmail-map regeneration on every message - each pipeline should
* regenerate only what it owns.
*/

resource "aws_sns_topic" "user_rules_changed" {
  name = "cabal-user-rules-changed"
  # Same SSE posture as address_changed above; set_rules gets the ViaService-
  # scoped KMS grant from the same shared Lambda policy.
  kms_master_key_id = "alias/aws/sns"
}

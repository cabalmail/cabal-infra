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

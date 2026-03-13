/**
* SNS topic for address-change fan-out.
*
* When the new/revoke Lambdas update the cabal-addresses DynamoDB table,
* they publish to this topic. Each SQS queue (one per tier) receives the
* notification and the reconfigure sidecar in each container picks it up.
*/

resource "aws_sns_topic" "address_changed" {
  name = "cabal-address-changed"
}

#!/usr/bin/env bash
# Converge the resource-based policy on the account's 10DLC phone
# number in AWS End User Messaging, sharing it with Amazon SNS.
#
# Cognito publishes SMS through SNS, and SNS can only originate from an
# End User Messaging phone number that has a resource policy granting
# the sns.amazonaws.com service principal sms-voice:SendTextMessage --
# "even if you are using the same AWS account" (AWS End User Messaging
# SMS User Guide, "Request a phone number"). The console's number-
# request wizard offers a checkbox that writes this policy; numbers
# provisioned through the RequestPhoneNumber API (as Terraform does)
# get no policy, and every SNS publish then fails silently with
# "No origination identity available to send to destination number".
#
# Terraform cannot own this: the AWS provider exposes no resource for
# EUM resource policies, so this runs as a post-apply step in
# infra.yml. put-resource-policy is a full overwrite, making this
# idempotent; steady-state it is a no-op rewrite of the same policy.
#
# No-op (exit 0) when the account has no 10DLC number yet - the number
# only exists once the campaign registration is approved and its id is
# supplied to Terraform.
set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

NUMBER_ARNS=$(aws pinpoint-sms-voice-v2 describe-phone-numbers \
  --query "PhoneNumbers[?NumberType=='TEN_DLC'].PhoneNumberArn" \
  --output text)

if [ -z "${NUMBER_ARNS}" ]; then
  echo "[sms-resource-policy] no 10DLC phone number in this account; nothing to do"
  exit 0
fi

for arn in ${NUMBER_ARNS}; do
  echo "[sms-resource-policy] sharing ${arn} with Amazon SNS"
  aws pinpoint-sms-voice-v2 put-resource-policy \
    --resource-arn "${arn}" \
    --policy "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "sns.amazonaws.com"},
      "Action": "sms-voice:SendTextMessage",
      "Resource": "${arn}",
      "Condition": {"StringEquals": {"aws:SourceAccount": "${ACCOUNT_ID}"}}
    }
  ]
}
EOF
)" >/dev/null
  echo "[sms-resource-policy] policy set on ${arn}"
done

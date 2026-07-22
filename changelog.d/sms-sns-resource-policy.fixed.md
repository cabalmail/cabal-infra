- **Cognito verification SMS never delivered.** The 10DLC phone number
  lacked the End User Messaging resource policy that shares it with
  Amazon SNS (required even within the owning account), so every
  Cognito-originated send was silently dropped with "No origination
  identity available to send to destination number". A new post-apply
  step (`put-sms-resource-policy.sh`) now converges the policy on the
  10DLC number, and `docs/sms-10dlc.md` documents the requirement, the
  silent-failure signature, and an SNS-path smoke test. The CI role
  needs one new grant: `sms-voice:PutResourcePolicy` (docs/aws.md).

- Reconciled the bootstrap "cicd" IAM policy in docs/aws.md with what the
  current Terraform code requires. Added the EC2 Image Builder (NAT AMI
  pipeline), EventBridge Scheduler (certbot renewal, DMARC processing),
  End User Messaging phone-number (optional, `TF_VAR_USE_EUM_SMS`), and
  CloudWatch alarm actions; alphabetized the action list; and noted the
  optional grants and the cross-account state-bucket consideration. A
  fresh-account bootstrap following the doc now works for the current
  terraform/infra and terraform/dns code.

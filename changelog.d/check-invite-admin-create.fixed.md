- **Terraform can create system users while the invitation gate is set.**
  The `check_invite` pre-sign-up trigger fires for `AdminCreateUser` too,
  and rejected the `ci-probe` user: the AWS provider normalizes
  `aws_cognito_user` validation-data keys like user attributes, so the
  invitation code arrived as `custom:invitationCode`. The trigger now
  exempts the `PreSignUp_AdminCreateUser` source: that caller is already
  IAM-authorized, and the gate exists to stop self-service signups. The
  same failure would have blocked the `master` and `dmarc` users in any
  environment brought up with the code set.

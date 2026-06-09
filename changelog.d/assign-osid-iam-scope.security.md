- The Cognito post-confirmation trigger (`assign_osid`) can no longer call
  `AdminUpdateUserAttributes` on any user in any pool in the account: its IAM
  policy now names the specific user-pool ARN it actually uses. The
  `logs:CreateLogGroup` grants on `assign_osid` and `check_invite` are likewise
  narrowed from every log group in the account to each function's own group.

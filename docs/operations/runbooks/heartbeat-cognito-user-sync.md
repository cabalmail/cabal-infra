# Runbook: heartbeat missed — `cognito-user-sync`

Fired by Healthchecks when the `cognito-user-sync` check has been silent past its 7-day grace beyond the 30-day expected cadence.

## What this means

The `assign_osid` post-confirmation Lambda has not pinged in 30+ days. This Lambda is the Cognito post-confirmation trigger — it fires once per new sign-up, increments the user counter, and pings Healthchecks. A completed Forgot Password reset fires it too; that run leaves the user's uid alone and only pings. The 30-day cadence is intentionally loose because **the Lambda only runs when somebody signs up or finishes a password reset**.

If sign-ups are rare (the common case for a single-operator Cabalmail), this alert is mostly a "are we still wired up correctly?" check, not a fast-feedback signal.

## Who/what is impacted

A broken post-confirmation step means new users will exist in Cognito but their post-sign-up provisioning is incomplete. Existing users are unaffected.

## First three things to check

1. **Has anyone signed up in the last 30 days?**
   ```sh
   aws cognito-idp list-users --user-pool-id <pool-id> --query 'Users[].UserCreateDate' --output text \
     | tr '\t' '\n' | sort | tail -5
   ```
   No recent sign-ups → benign. Pause the check or extend its grace; this isn't a real issue.
2. **If there were sign-ups, did the Lambda run for each?**
   ```sh
   aws logs tail /aws/lambda/assign_osid --since 30d | head -50
   ```
3. **Is the Lambda still wired as the trigger?**
   ```sh
   aws cognito-idp describe-user-pool --user-pool-id <pool-id> \
     --query 'UserPool.LambdaConfig.PostConfirmation'
   ```
   Empty / wrong ARN → Terraform regression; re-apply.

## Escalation

- This is the loosest heartbeat in the system. Severity in Phase 2 is `critical` because Healthchecks doesn't have per-check severity overrides; in practice treat it as `info` — investigate during business hours, no wake-up justified. Phase 4 §3 IaC will fix this with declarative per-check severity once Healthchecks config is code.
- If the Lambda needs to fire to clear the alert, manually invoke it with a password-reset source, which only pings — it takes no uid, writes nothing to Cognito and rolls no service:
  ```sh
  aws lambda invoke --function-name assign_osid \
    --cli-binary-format raw-in-base64-out \
    --payload '{"userPoolId": "<pool-id>", "userName": "manual-heartbeat", "triggerSource": "PostConfirmation_ConfirmForgotPassword"}' \
    /tmp/out.json
  ```
  Never invoke it with `PostConfirmation_ConfirmSignUp`: that takes the next uid from `cabal-counter` before failing on the nonexistent user. The simpler path is just pause the check and accept "no signal until next sign-up".

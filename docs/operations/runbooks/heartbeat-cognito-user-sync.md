# Runbook: heartbeat missed — `cognito-user-sync`

Fired by Healthchecks when the `cognito-user-sync` check has been silent past its 7-day grace beyond the 30-day expected cadence.

## What this means

The `cabal-cognito-counter` post-confirmation Lambda has not pinged in 30+ days. This Lambda is the Cognito post-confirmation trigger — it fires once per new sign-up, increments the user counter, and pings Healthchecks. The 30-day cadence is intentionally loose because **the Lambda only runs when somebody signs up**.

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
   aws logs tail /aws/lambda/cabal-cognito-counter --since 30d | head -50
   ```
3. **Is the Lambda still wired as the trigger?**
   ```sh
   aws cognito-idp describe-user-pool --user-pool-id <pool-id> \
     --query 'UserPool.LambdaConfig.PostConfirmation'
   ```
   Empty / wrong ARN → Terraform regression; re-apply.

## Escalation

- This is the loosest heartbeat in the system. Severity in Phase 2 is `critical` because Healthchecks doesn't have per-check severity overrides; in practice treat it as `info` — investigate during business hours, no wake-up justified. Phase 4 §3 IaC will fix this with declarative per-check severity once Healthchecks config is code.
- If the Lambda needs to fire to clear the alert, manually invoke it (it's idempotent on a noop input):
  ```sh
  aws lambda invoke --function-name cabal-cognito-counter \
    --cli-binary-format raw-in-base64-out \
    --payload '{"userPoolId": "<pool-id>", "userName": "manual-heartbeat", "triggerSource": "PostConfirmation_ConfirmSignUp"}' \
    /tmp/out.json
  ```
  *Verify the function tolerates this payload before doing it in prod.* The simpler path is just pause the check and accept "no signal until next sign-up".

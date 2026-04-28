# Runbook: heartbeat missed — `aws-backup`

Fired by Healthchecks when the `aws-backup` check has been silent past its 6-hour grace beyond the 24-hour expected cadence.

## What this means

AWS Backup did not complete a successful `BACKUP_JOB` for the daily plan, so the `cabal-backup-heartbeat` Lambda (driven by an EventBridge `Backup Job State Change` rule) didn't ping. Possible causes:
- The backup plan didn't run (vault deleted, plan disabled, IAM regression).
- The backup ran but failed (capacity, encryption key issue, source resource absent).
- The job succeeded but the `backup_heartbeat` Lambda failed before pinging (SSM value missing, network).

## Who/what is impacted

If `var.backup = true`, the daily backup covers the EFS file system and `cabal-addresses` DynamoDB table. A skipped day means a 24-hour gap in recovery points. Cabalmail's RPO target during 0.7.0 is "best-effort daily" — one missed day is tolerable, three in a row is not.

If `var.backup = false`, this alert is a false positive: there's no plan to ping. Pause the check in Healthchecks and clear the SSM parameter.

## First three things to check

1. **Is `var.backup` actually `true`?**
   ```sh
   aws backup list-backup-plans --query 'BackupPlansList[?contains(BackupPlanName,`cabal`)]'
   ```
   No plan returned → confirm `TF_VAR_BACKUP=true` in the GitHub environment for this stack and re-apply Terraform. Pause the heartbeat in Healthchecks while you reconcile.
2. **Did the latest job succeed?**
   ```sh
   aws backup list-backup-jobs --by-backup-vault-name <vault> --max-results 5 \
     --query 'BackupJobs[].{state:State,resource:ResourceArn,started:CreationDate,completed:CompletionDate,reason:StatusMessage}'
   ```
   `COMPLETED` → see step 3. `FAILED` / `ABORTED` → the StatusMessage usually explains.
3. **Did the Lambda fail?**
   ```sh
   aws logs tail /aws/lambda/cabal-backup-heartbeat --since 48h | head -100
   ```
   Look for "ping_url not configured" (SSM placeholder still in place) or HTTP errors reaching Healthchecks.

## Escalation

- **Plan disabled / vault missing**: that's a config drift. Don't manually re-enable in the console — re-apply Terraform from `0.7.0` so state matches.
- **Job failure pattern**: AWS Backup occasionally fails with capacity-related errors. Inspect `StatusMessage`; if it's transient, leave it and the next day's run will recover. Trends > 1 in 7 should open an issue.
- **`backup_heartbeat` itself broken**: see [lambda-errors.md](./lambda-errors.md). The fix is usually re-seeding the SSM ping URL — see [docs/monitoring.md §12](../../monitoring.md#12-create-one-check-per-scheduled-job).
- This alert is `critical` but the buffer-to-impact is large (you'd need a backup *and* a need-to-restore, both rare). Treat as next-business-day urgency.

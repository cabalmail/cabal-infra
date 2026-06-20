# Disaster recovery

When `var.backup` is true, AWS Backup takes a nightly (00:00 UTC) recovery point of the `cabal-addresses` DynamoDB table and the EFS mailstore into the `cabal-backup` vault, copies each recovery point to the `cabal-backup-dr` vault in `var.dr_region` (default `us-west-2`), and retains everything for one year (warm for 30 days, cold storage after). Both vaults are lock-protected in governance mode with a 30-day minimum retention: nothing younger than 30 days can be deleted by anyone, including the deploy principal, without first removing the vault lock - a separate, CloudTrail-visible API call.

The other DynamoDB tables (`cabal-counter`, `cabal-user-preferences`, `cabal-user-domain-access`, `cabal-dmarc-reports`) are not in the backup plan; their recovery path is point-in-time recovery (PITR), which every table has enabled. The S3 message cache is not backed up at all - it is a cache; the mailstore on EFS is the source of truth.

## One-time account setup: advanced DynamoDB backup features

Cross-region copy of DynamoDB recovery points only works when the account/region has opted in to advanced DynamoDB backup features ("full AWS Backup management"). This is a one-time, account-region-wide setting, applied out of band rather than in Terraform (the corresponding Terraform resource is a region-wide singleton that produces perpetual plan diffs unless it enumerates every resource type):

```sh
aws backup update-region-settings \
  --resource-type-management-preference DynamoDB=true \
  --region <primary-region>
```

Only recovery points created *after* the opt-in can be copied; until then the nightly DynamoDB copy job fails (EFS copies are unaffected). Verify with:

```sh
aws backup describe-region-settings --region <primary-region>
```

## Verifying the posture

```sh
# Vault lock active, 30-day floor
aws backup describe-backup-vault --backup-vault-name cabal-backup
# expect: "MinRetentionDays": 30, "Locked": true

# Last night's recovery points exist in the primary vault
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name cabal-backup --query 'RecoveryPoints[0:4].[CreationDate,ResourceType,Status]'

# ... and were copied to the DR region
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name cabal-backup-dr --region <dr-region> \
  --query 'RecoveryPoints[0:4].[CreationDate,ResourceType,Status]'

# Copy jobs are succeeding
aws backup list-copy-jobs --by-state COMPLETED --max-results 5

# PITR on a table. NOTE: describe-table does NOT report PITR (it shows
# SSE and deletion protection only); PITR lives behind the
# continuous-backups API.
aws dynamodb describe-continuous-backups --table-name cabal-counter
# expect: "PointInTimeRecoveryStatus": "ENABLED"
```

## Runbook: restore the addresses table from last night

DynamoDB restores always go to a *new* table; there is no in-place restore.

1. Find the recovery point:

   ```sh
   aws backup list-recovery-points-by-backup-vault --backup-vault-name cabal-backup \
     --by-resource-type DynamoDB --query 'RecoveryPoints[0].RecoveryPointArn'
   ```

2. Start the restore to a new table name (e.g. `cabal-addresses-restored`), using the `cabal-backup-role` IAM role created by the backup module.
3. When the restored table is ACTIVE, compare item counts against expectations, then cut over: the application reads the table by name, so the cutover is a scan-copy back into `cabal-addresses` (small table, a few thousand items at most) - not a rename. `aws dynamodb scan` piped to `batch-write-item`, or a few lines of Python.
4. Trigger mail-tier reconfiguration (any address mutation does this, or roll the ECS services) so the sendmail maps regenerate from the restored data.

For the PITR-only tables, use `aws dynamodb restore-table-to-point-in-time` with the same scan-copy cutover.

## Runbook: restore the mailstore (EFS)

AWS Backup restores EFS either to a new filesystem or into the source filesystem under a dated recovery directory (`aws-backup-restore_<timestamp>`); it never overwrites in place.

1. Find the EFS recovery point (as above, `--by-resource-type EFS`).
2. For a single mailbox ("user deleted mail and changed their mind"): do an item-level restore of `/<user>` into the source filesystem, then move the needed maildir files from the recovery directory into the user's maildir and fix ownership to match the user's OS uid (see the `cabal-counter` table / `sync-users.sh`). Dovecot picks up restored maildir files on next access; delete the recovery directory afterwards.
3. For whole-mailstore loss: restore to a new filesystem, then repoint `module.efs`'s filesystem at it (import the new filesystem into Terraform state or update the data plane deliberately), and roll the ECS services. This is the slow path; expect hours for a large mailstore.

## Runbook: rebuild from the cross-region copy

If the primary region (or every primary-region recovery point) is gone:

1. Recovery points in `cabal-backup-dr` restore *in the DR region*. For a primary-region rebuild, first copy the recovery point back:

   ```sh
   aws backup start-copy-job --region <dr-region> \
     --recovery-point-arn <arn-in-dr-vault> \
     --source-backup-vault-name cabal-backup-dr \
     --destination-backup-vault-arn arn:aws:backup:<primary-region>:<account>:backup-vault:cabal-backup \
     --iam-role-arn arn:aws:iam::<account>:role/cabal-backup-role
   ```

2. Then run the DynamoDB / EFS restore runbooks above against the copied-back recovery point. (If the primary region itself is down, restoring into the DR region is possible but means standing up the whole stack there - that is a region migration, not a runbook.)

## Removing the vault lock (legitimate cases)

Governance mode means an admin with `backup:DeleteBackupVaultLockConfiguration` can remove the lock at any time; the call lands in CloudTrail. The legitimate reasons are environment teardown and retention-policy changes:

```sh
aws backup delete-backup-vault-lock-configuration --backup-vault-name cabal-backup
aws backup delete-backup-vault-lock-configuration --backup-vault-name cabal-backup-dr --region <dr-region>
```

## Environment teardown with backup enabled

A `terraform destroy` against an environment with `backup = true` fails at the vaults: the destroy workflow strips Terraform's `prevent_destroy` guard, but AWS refuses to delete a vault that still contains recovery points, and the vault lock refuses to delete recovery points younger than 30 days. To tear down deliberately:

1. Remove both vault-lock configurations (above).
2. Delete all recovery points from both vaults (`aws backup delete-recovery-point`).
3. Run the destroy workflow.

That this takes three deliberate steps is the feature.

## Exercise cadence

Run the addresses-table and single-mailbox EFS restores against the development environment after any change to the backup module, and at least once a year otherwise. The cross-region copy-back drill is worth one execution to validate IAM and vault wiring; afterwards, verifying that copy jobs succeed nightly (see "Verifying the posture") is sufficient.

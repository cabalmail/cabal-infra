- The AWS Backup vault is now lock-protected (governance mode, 30-day
  minimum retention) and every nightly recovery point is copied to a
  second locked vault in `var.dr_region` (default `us-west-2`), so a
  compromised admin or a regional event cannot erase the last 30 days
  of backups. Recovery-point retention is now bounded at one year (30
  days warm, then cold storage) instead of keep-forever. Cross-region
  copy of DynamoDB recovery points requires a one-time, per-account
  opt-in to advanced DynamoDB backup features; see
  docs/disaster-recovery.md.

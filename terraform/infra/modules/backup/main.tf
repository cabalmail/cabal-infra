/**
* Creates AWS Backup configuration for preserving DynamoDB (source of address data) and Elastic Filesystem (mailstore). This module is skipped unless the main module is called with `var.backup == true`. If invoked, it makes it impossible to cleanly execute a destroy plan, because it enforces `prevent_destroy` on the Backup vaults; retiring an environment that has backup enabled requires first removing the vault-lock configurations and the `prevent_destroy` settings in code. Recovery points are retained for one year (30 days warm, then cold storage) and every backup is copied to a locked vault in a second region, so neither a regional event nor a compromised admin inside the primary region can erase recovery capability. NOTE: cross-region copy of DynamoDB recovery points requires the account/region to have opted in to advanced DynamoDB backup features (a one-time, account-region-wide setting; see docs/disaster-recovery.md) - without it the nightly DynamoDB copy jobs fail while EFS copies still succeed.
*/

data "aws_region" "current" {}

data "aws_region" "dr" {
  provider = aws.dr_region
}

resource "aws_backup_vault" "backup" {
  name = "cabal-backup"
  lifecycle {
    prevent_destroy = true
  }
}

# Vault lock in governance mode (changeable_for_days unset). Recovery
# points younger than min_retention_days cannot be deleted by anyone,
# including the deploy principal; a privileged admin can remove the
# lock itself with one extra, CloudTrail-visible API call
# (DeleteBackupVaultLockConfiguration). Compliance mode (setting
# changeable_for_days) would make the lock immutable for the retention
# period - stronger against ransomware but irreversible against
# fat-fingers; the governance trade-off is deliberate (see
# docs/0.10.x/resilience-continuity-hardening-plan.md, revisit
# annually).
resource "aws_backup_vault_lock_configuration" "backup" {
  backup_vault_name  = aws_backup_vault.backup.name
  min_retention_days = 30
  max_retention_days = 365
}

# Second-region vault. A copy of every nightly recovery point lands
# here (see copy_action below), so a regional outage or a deletion
# spree scoped to the primary region does not lose the backup history.
resource "aws_backup_vault" "backup_dr" {
  provider = aws.dr_region
  name     = "cabal-backup-dr"
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = data.aws_region.dr.region != data.aws_region.current.region
      error_message = "var.dr_region must differ from var.aws_region; a same-region copy defeats the purpose of the DR vault."
    }
  }
}

resource "aws_backup_vault_lock_configuration" "backup_dr" {
  provider           = aws.dr_region
  backup_vault_name  = aws_backup_vault.backup_dr.name
  min_retention_days = 30
  max_retention_days = 365
}

resource "aws_iam_role" "backup" {
  name               = "cabal-backup-role"
  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": ["sts:AssumeRole"],
      "Effect": "allow",
      "Principal": {
        "Service": ["backup.amazonaws.com"]
      }
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "backup" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
  role       = aws_iam_role.backup.name
}

resource "aws_backup_plan" "backup" {
  name = "cabal-backup-plan"
  rule {
    rule_name         = "cabal-backup-plan-rule"
    target_vault_name = aws_backup_vault.backup.name
    schedule          = "cron(0 0 * * ? *)"

    # Bounded retention (the previous default was keep-forever): warm
    # for 30 days, cold storage after that, deleted after a year. AWS
    # requires delete_after >= cold_storage_after + 90. Recovery points
    # created before this lifecycle landed keep their original
    # (unbounded) retention and can be deleted by hand once aged out.
    lifecycle {
      cold_storage_after = 30
      delete_after       = 365
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.backup_dr.arn
      lifecycle {
        delete_after = 365
      }
    }
  }
}

resource "aws_backup_selection" "backup" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "cabal-backup"
  plan_id      = aws_backup_plan.backup.id

  resources = [
    var.table,
    var.efs,
  ]
}

/**
* Creates AWS Backup configuration for preserving DynamoDB (source of address data) and Elastic Filesystem (mailstore). This module is skipped unless the main module is called with `var.backup == true`. If invoked, it will make it impossible to cleanly execute a destroy plan, because it enforces `prevent_destroy` on the Backup vault.
*/

resource "aws_backup_vault" "backup" {
  name = "cabal-backup"
  lifecycle {
    prevent_destroy = false
  }
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

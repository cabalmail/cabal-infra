resource "aws_backup_vault" "backup" {
  name = "cabal-backup"
  lifecycle {
    prevent_destroy = true
  }
}

# resource "aws_backup_region_settings" "services" {
#   resource_type_opt_in_preference = {
#     "DynamoDB"        = true
#     "Aurora"          = false
#     "EBS"             = false
#     "EC2"             = false
#     "EFS"             = true
#     "FSx"             = false
#     "RDS"             = false
#     "Storage Gateway" = false
#   }
# }

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
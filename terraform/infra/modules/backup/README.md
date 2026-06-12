<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />
<p><a href="/README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">

Creates AWS Backup configuration for preserving DynamoDB (source of address data) and Elastic Filesystem (mailstore). This module is skipped unless the main module is called with `var.backup == true`. If invoked, it makes it impossible to cleanly execute a destroy plan, because it enforces `prevent_destroy` on the Backup vaults; retiring an environment that has backup enabled requires first removing the vault-lock configurations and the `prevent_destroy` settings in code. Recovery points are retained for one year (30 days warm, then cold storage) and every backup is copied to a locked vault in a second region, so neither a regional event nor a compromised admin inside the primary region can erase recovery capability. NOTE: cross-region copy of DynamoDB recovery points requires the account/region to have opted in to advanced DynamoDB backup features (a one-time, account-region-wide setting; see docs/disaster-recovery.md) - without it the nightly DynamoDB copy jobs fail while EFS copies still succeed.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_efs"></a> [efs](#input\_efs) | ARN of elastic filesystem to back up. | `string` | n/a | yes |
| <a name="input_table"></a> [table](#input\_table) | ARN of DynamoDB table to back up. | `string` | n/a | yes |
## Modules

No modules.
## Outputs

No outputs.
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.32 |
| <a name="provider_aws.dr_region"></a> [aws.dr\_region](#provider\_aws.dr\_region) | ~> 5.32 |
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.1.2 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.32 |
## Resources

| Name | Type |
|------|------|
| [aws_backup_plan.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_plan) | resource |
| [aws_backup_selection.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_selection) | resource |
| [aws_backup_vault.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_backup_vault.backup_dr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_backup_vault_lock_configuration.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault_lock_configuration) | resource |
| [aws_backup_vault_lock_configuration.backup_dr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault_lock_configuration) | resource |
| [aws_iam_role.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_region.dr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

</div>
<!-- END_TF_DOCS -->
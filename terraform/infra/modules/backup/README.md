<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />
<p><a href="/README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">

Creates AWS Backup configuration for preserving DynamoDB (source of address data) and Elastic Filesystem (mailstore). This module is skipped unless the main module is called with `var.backup == true`. If invoked, it will make it impossible to cleanly execute a destroy plan, because it enforces `prevent_destroy` on the Backup vault.

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
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 4.41 |
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.1.2 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 4.41 |
## Resources

| Name | Type |
|------|------|
| [aws_backup_plan.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_plan) | resource |
| [aws_backup_selection.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_selection) | resource |
| [aws_backup_vault.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_iam_role.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |

</div>
<!-- END_TF_DOCS -->
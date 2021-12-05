<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 35px; float:left"><img src="../../docs/logo.png" width="35" />
<p>[Main documentation](../../README.md)</p>
</div>
# Header Start

# Header End
# Footer Start

# Footer End
# Inputs Start
## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_efs"></a> [efs](#input\_efs) | ARN of elastic filesystem to back up. | `any` | n/a | yes |
| <a name="input_table"></a> [table](#input\_table) | ARN of DynamoDB table to back up. | `any` | n/a | yes |
# Inputs End
# Modules Start
## Modules

No modules.
# Modules End
# Outputs Start
## Outputs

No outputs.
# Outputs End
# Providers Start
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |
# Providers End
# Requirements Start
## Requirements

No requirements.
# Requirements End
# Resources Start
## Resources

| Name | Type |
|------|------|
| [aws_backup_plan.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_plan) | resource |
| [aws_backup_selection.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_selection) | resource |
| [aws_backup_vault.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/backup_vault) | resource |
| [aws_iam_role.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.backup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
# Resources End
<!-- END_TF_DOCS -->
<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />
<p><a href="/README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">

Creates an Elastic Filesystem for the mailstore. This filesystem is mounted on IMAP machines on the /home directory.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_private_subnet_ids"></a> [private\_subnet\_ids](#input\_private\_subnet\_ids) | Private subnets | `list(string)` | n/a | yes |
| <a name="input_vpc_cidr_block"></a> [vpc\_cidr\_block](#input\_vpc\_cidr\_block) | CIDR block for the VPC | `string` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID | `string` | n/a | yes |
## Modules

No modules.
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_efs_arn"></a> [efs\_arn](#output\_efs\_arn) | ARN of elastic filesystem. |
| <a name="output_efs_dns"></a> [efs\_dns](#output\_efs\_dns) | Domain name of elastic filesystem. |
| <a name="output_efs_id"></a> [efs\_id](#output\_efs\_id) | ID of elastic filesystem. |
| <a name="output_smtp_queue_access_point_id"></a> [smtp\_queue\_access\_point\_id](#output\_smtp\_queue\_access\_point\_id) | EFS access point id for the shared smtp-out sendmail MTA queue. |
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.32 |
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.1.2 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.32 |
## Resources

| Name | Type |
|------|------|
| [aws_efs_access_point.smtp_queue](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_access_point) | resource |
| [aws_efs_file_system.mailstore](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.mailstore](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_security_group.mailstore](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |

</div>
<!-- END_TF_DOCS -->
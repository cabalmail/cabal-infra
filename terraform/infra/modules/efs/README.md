<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 100px; float:left; height: 100%; padding-right: 1em;"><img src="../../docs/logo.png" width="100" />
<p><a href="../../README.md">Main documentation</a></p>
</div>


## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | Private subnets | `any` | n/a | yes |
| <a name="input_vpc"></a> [vpc](#input\_vpc) | VPC | `any` | n/a | yes |
## Modules

No modules.
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_efs_arn"></a> [efs\_arn](#output\_efs\_arn) | n/a |
| <a name="output_efs_dns"></a> [efs\_dns](#output\_efs\_dns) | n/a |
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |
## Requirements

No requirements.
## Resources

| Name | Type |
|------|------|
| [aws_efs_file_system.mailstore](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system) | resource |
| [aws_efs_mount_target.mailstore](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target) | resource |
| [aws_security_group.mailstore](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
<!-- END_TF_DOCS -->
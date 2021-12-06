<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="../../docs/logo.png" width="100" />
<p><a href="../../README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">



## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_artifact_bucket"></a> [artifact\_bucket](#input\_artifact\_bucket) | S3 bucket where cookbooks are stored. | `string` | n/a | yes |
| <a name="input_chef_license"></a> [chef\_license](#input\_chef\_license) | Must be the string 'accept' in order to install and use Chef Infra Client | `string` | n/a | yes |
| <a name="input_cidr_block"></a> [cidr\_block](#input\_cidr\_block) | Local CIDR range | `string` | n/a | yes |
| <a name="input_client_id"></a> [client\_id](#input\_client\_id) | App client ID for Cognito User Pool | `string` | n/a | yes |
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | Control domain | `string` | n/a | yes |
| <a name="input_efs_dns"></a> [efs\_dns](#input\_efs\_dns) | DNS of Elastic File System | `string` | n/a | yes |
| <a name="input_ports"></a> [ports](#input\_ports) | Ports to open in security group | `list(number)` | n/a | yes |
| <a name="input_private_ports"></a> [private\_ports](#input\_private\_ports) | Ports to open for local traffic in security group | `list(number)` | n/a | yes |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | Subnets for imap ec2 instances. | `list` | n/a | yes |
| <a name="input_private_zone_id"></a> [private\_zone\_id](#input\_private\_zone\_id) | Zone ID for internal lookups | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region | `string` | n/a | yes |
| <a name="input_s3_arn"></a> [s3\_arn](#input\_s3\_arn) | S3 bucket arn | `string` | n/a | yes |
| <a name="input_scale"></a> [scale](#input\_scale) | Min, max, and desired settings for autoscale group | `map` | n/a | yes |
| <a name="input_table_arn"></a> [table\_arn](#input\_table\_arn) | DynamoDB table arn | `string` | n/a | yes |
| <a name="input_target_groups"></a> [target\_groups](#input\_target\_groups) | List of load balancer target groups in which to register IMAP instances. | `list` | n/a | yes |
| <a name="input_type"></a> [type](#input\_type) | Type of server, 'imap', 'smtp-in', or 'smtp-out. | `string` | n/a | yes |
| <a name="input_user_pool_arn"></a> [user\_pool\_arn](#input\_user\_pool\_arn) | ARN of the Cognito User Pool | `string` | n/a | yes |
| <a name="input_user_pool_id"></a> [user\_pool\_id](#input\_user\_pool\_id) | ID of the Cognito User Pool | `string` | n/a | yes |
| <a name="input_vpc"></a> [vpc](#input\_vpc) | VPC for the load balancer. | `map` | n/a | yes |
## Modules

No modules.
## Outputs

No outputs.
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |
## Requirements

No requirements.
## Resources

| Name | Type |
|------|------|
| [aws_autoscaling_group.asg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group) | resource |
| [aws_iam_instance_profile.asg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_policy.node_permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.node_permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.attachment_1](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.attachment_2](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_launch_configuration.asg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_configuration) | resource |
| [aws_security_group.sg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group_rule.allow_in_local](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.allow_in_world](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.allow_out](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_ami.amazon_linux_2](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_default_tags.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/default_tags) | data source |
| [aws_iam_policy.ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy) | data source |

</div>
<!-- END_TF_DOCS -->
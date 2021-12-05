<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 35px; float:left"><img src="../../docs/logo.png" width="35" />
<p><a href="../../README.md">Main documentation</a></p>
</div>
# Header Start

# Header End
# Footer Start

# Footer End
# Inputs Start
## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | Base for auth domain. E.g., if control\_domain is example.com, then the autho domain will be auth.example.com. | `string` | n/a | yes |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Zone ID for creating DNS records for auth domain. | `string` | n/a | yes |
# Inputs End
# Modules Start
## Modules

No modules.
# Modules End
# Outputs Start
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_user_pool_arn"></a> [user\_pool\_arn](#output\_user\_pool\_arn) | n/a |
| <a name="output_user_pool_client_id"></a> [user\_pool\_client\_id](#output\_user\_pool\_client\_id) | n/a |
| <a name="output_user_pool_id"></a> [user\_pool\_id](#output\_user\_pool\_id) | n/a |
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
| [aws_cognito_user_pool.users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cognito_user_pool) | resource |
| [aws_cognito_user_pool_client.users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cognito_user_pool_client) | resource |
| [aws_iam_policy.users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.sns_users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.users](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
# Resources End
<!-- END_TF_DOCS -->
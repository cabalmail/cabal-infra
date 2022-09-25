<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />
<p><a href="/README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">

Stands up the following resources to implement a web application that allows users to manage (create and revoke) their email addresses:

- S3 bucket for static assets
- Static assets as objects stored in S3
- Lambda functions for three calls: new address, list addresses, revoke address
- API Gateway for mediating access to the Lambda functioins
- CloudFront to cache and accelerate the application
- DNS alias for the application
- SSM documents for propagating changes to the IMAP and SMTP servers (still in development)

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cert_arn"></a> [cert\_arn](#input\_cert\_arn) | ARN for the AWS Certificate Manager certificate for the control domain. | `string` | n/a | yes |
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | The control domain. | `string` | n/a | yes |
| <a name="input_dev_mode"></a> [dev\_mode](#input\_dev\_mode) | If true, forces Cloudfront to non-caching configuration. | `bool` | n/a | yes |
| <a name="input_domains"></a> [domains](#input\_domains) | List of email domains. | `list` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | The AWS region. | `string` | n/a | yes |
| <a name="input_relay_ips"></a> [relay\_ips](#input\_relay\_ips) | Egress IP addresses. | `list(string)` | n/a | yes |
| <a name="input_repo"></a> [repo](#input\_repo) | Repo tag value for SSM run command target. | `string` | n/a | yes |
| <a name="input_stage_name"></a> [stage\_name](#input\_stage\_name) | Name for the API Gateway stage. Default: prod. | `string` | `"prod"` | no |
| <a name="input_user_pool_client_id"></a> [user\_pool\_client\_id](#input\_user\_pool\_client\_id) | Client ID for authenticating with the Cognito user pool. | `string` | n/a | yes |
| <a name="input_user_pool_id"></a> [user\_pool\_id](#input\_user\_pool\_id) | ID of the Cognito user pool. | `string` | n/a | yes |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Route 53 zone ID for the control domain. | `string` | n/a | yes |
## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_cabal_list_method"></a> [cabal\_list\_method](#module\_cabal\_list\_method) | ./modules/call | n/a |
| <a name="module_cabal_new_method"></a> [cabal\_new\_method](#module\_cabal\_new\_method) | ./modules/call | n/a |
| <a name="module_cabal_revoke_method"></a> [cabal\_revoke\_method](#module\_cabal\_revoke\_method) | ./modules/call | n/a |
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
| [aws_api_gateway_account.apigw_account](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_account) | resource |
| [aws_api_gateway_authorizer.api_auth](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_authorizer) | resource |
| [aws_api_gateway_deployment.deployment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_deployment) | resource |
| [aws_api_gateway_method_settings.settings](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_method_settings) | resource |
| [aws_api_gateway_rest_api.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_rest_api) | resource |
| [aws_api_gateway_stage.api_stage](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_stage) | resource |
| [aws_cloudfront_distribution.cdn](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_iam_role.cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_route53_record.admin_cname](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.spf](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_s3_bucket_policy.react_app_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_object.website_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_ssm_document.run_chef_now](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_document) | resource |
| [aws_ssm_parameter.cf_distribution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_ssm_parameter.origin_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_ssm_parameter.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

</div>
<!-- END_TF_DOCS -->
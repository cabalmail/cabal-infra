<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />
<p><a href="/README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">

# Cabalmail DNS

The small Terraform stack in this directory stands up a Route53 Zone for the control domain of a Cabalmail system. In order for the main stack to run successfully, you must observe the output from this stack and [update your domain registration with the indicated nameservers](../../docs/registrar.md). See the [README.md](../../README.md) at the root of this repository for general information, and the [setup documentation](../../docs/setup.md) for specific steps.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region in which to provision primary infrastructure. Default us-west-1. | `string` | `"us-west-1"` | no |
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | The domain used for naming your email infrastructure. E.g., if you want to host imap.example.com and smtp-out.example.com, then this would be 'example.com'. This domain is not used for email addresses. | `string` | n/a | yes |
| <a name="input_github_token"></a> [github\_token](#input\_github\_token) | Personal access token for github. Used to trigger workflows from Terraform. | `string` | n/a | yes |
| <a name="input_prod"></a> [prod](#input\_prod) | Set to true to treat this stack as a production workload. | `bool` | `false` | no |
| <a name="input_repo"></a> [repo](#input\_repo) | This repository. Used for resource tagging. | `string` | `"https://github.com/ccarr-cabal/cabal-infra/tree/main"` | no |
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_control_domain_name_servers"></a> [control\_domain\_name\_servers](#output\_control\_domain\_name\_servers) | n/a |
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 4.0.0 |
| <a name="provider_http"></a> [http](#provider\_http) | n/a |
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.1.2 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 4.0.0 |
## Resources

| Name | Type |
|------|------|
| [aws_route53_zone.cabal_control_zone](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone) | resource |
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_ssm_parameter.name](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.zone](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [http_http.trigger_builds](https://registry.terraform.io/providers/hashicorp/http/latest/docs/data-sources/http) | data source |

</div>
<!-- END_TF_DOCS -->
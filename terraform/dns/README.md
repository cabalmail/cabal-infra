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
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | The domain used for naming your email infrastructure. E.g., if you want to host imap.example.com and smtp-out.example.com, then this would be 'example.com'. It may also be listed in the main stack's mail\_domains to host email addresses on its subdomains; its apex is never addressable. | `string` | n/a | yes |
| <a name="input_dnssec_enabled"></a> [dnssec\_enabled](#input\_dnssec\_enabled) | Whether to create a KSK and enable DNSSEC signing on the control-domain zone. Enabling signing is safe on its own; the chain of trust only forms when the operator publishes the DS record at the registrar afterwards (sign first, DS second - see docs/dnssec.md). Default false. | `bool` | `false` | no |
| <a name="input_prod"></a> [prod](#input\_prod) | Set to true to treat this stack as a production workload. | `bool` | `false` | no |
| <a name="input_repo"></a> [repo](#input\_repo) | This repository. Used for resource tagging. | `string` | `"https://github.com/ccarr-cabal/cabal-infra/tree/main"` | no |
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_control_domain_ds_record"></a> [control\_domain\_ds\_record](#output\_control\_domain\_ds\_record) | Null until var.dnssec\_enabled is true. Once signing is verified, the operator copies this DS record to the domain registrar to establish the chain of trust - sign first, DS second. See docs/dnssec.md. |
| <a name="output_control_domain_name_servers"></a> [control\_domain\_name\_servers](#output\_control\_domain\_name\_servers) | n/a |
| <a name="output_control_domain_zone_id"></a> [control\_domain\_zone\_id](#output\_control\_domain\_zone\_id) | n/a |
| <a name="output_control_domain_zone_name"></a> [control\_domain\_zone\_name](#output\_control\_domain\_zone\_name) | n/a |
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 4.0.0 |
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.1.2 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 4.0.0 |
## Resources

| Name | Type |
|------|------|
| [aws_kms_alias.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_route53_hosted_zone_dnssec.control](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_hosted_zone_dnssec) | resource |
| [aws_route53_key_signing_key.control](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_key_signing_key) | resource |
| [aws_route53_zone.cabal_control_zone](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.dnssec_key_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

</div>
<!-- END_TF_DOCS -->

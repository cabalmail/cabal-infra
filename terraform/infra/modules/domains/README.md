<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />
<p><a href="/README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">

Creates Route 53 zones for all mail domains. When the control domain is also listed as a mail domain its bootstrap zone is reused rather than duplicated. DNSSEC signing for the mail zones is opt-in via dnssec_enabled (one shared us-east-1 KMS key, per-zone KSKs); see docs/dnssec.md for the registrar DS workflow.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | The control domain. When it also appears in mail\_domains, its pre-existing bootstrap zone is reused instead of creating a duplicate hosted zone for the same name. | `string` | n/a | yes |
| <a name="input_control_domain_zone_id"></a> [control\_domain\_zone\_id](#input\_control\_domain\_zone\_id) | Route 53 zone id of the bootstrap control-domain zone (from the dns stack). | `string` | n/a | yes |
| <a name="input_dnssec_enabled"></a> [dnssec\_enabled](#input\_dnssec\_enabled) | Whether to create per-zone KSKs and enable DNSSEC signing on the mail-domain zones (sign first, DS second - see docs/dnssec.md). | `bool` | `false` | no |
| <a name="input_mail_domains"></a> [mail\_domains](#input\_mail\_domains) | List of mail domains. | `list(string)` | n/a | yes |
## Modules

No modules.
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_domains"></a> [domains](#output\_domains) | List of maps with domains and their Route 53 zone IDs. |
| <a name="output_ds_records"></a> [ds\_records](#output\_ds\_records) | Per-apex DS record values to publish at each domain registrar once signing is verified. Empty until dnssec\_enabled is true. |
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
| [aws_kms_alias.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.dnssec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_route53_hosted_zone_dnssec.mail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_hosted_zone_dnssec) | resource |
| [aws_route53_key_signing_key.mail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_key_signing_key) | resource |
| [aws_route53_zone.mail_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.dnssec_key_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_route53_zone.control](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |

</div>
<!-- END_TF_DOCS -->
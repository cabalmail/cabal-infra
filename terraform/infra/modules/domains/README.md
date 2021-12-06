<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="../../docs/logo.png" width="100" />
<p><a href="../../README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">



## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_mail_domains"></a> [mail\_domains](#input\_mail\_domains) | List of mail domains. | `list(string)` | n/a | yes |
## Modules

No modules.
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_domains"></a> [domains](#output\_domains) | List of maps with domains and their Route 53 zone IDs. |
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |
## Requirements

No requirements.
## Resources

| Name | Type |
|------|------|
| [aws_route53_zone.mail_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone) | resource |

</div>
<!-- END_TF_DOCS -->
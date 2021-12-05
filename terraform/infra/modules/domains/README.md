<!-- BEGIN_TF_DOCS -->
# Cabalmail
<table><tr><td><img src="../../docs/logo.png" width="35" />
[Main documentation](../../README.md)
</td><td>
# Header Start

# Header End
# Footer Start

# Footer End
# Inputs Start
## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_mail_domains"></a> [mail\_domains](#input\_mail\_domains) | n/a | `list(string)` | n/a | yes |
# Inputs End
# Modules Start
## Modules

No modules.
# Modules End
# Outputs Start
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_domains"></a> [domains](#output\_domains) | n/a |
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
| [aws_route53_zone.mail_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone) | resource |
# Resources End
</td></tr></table>
<!-- END_TF_DOCS -->
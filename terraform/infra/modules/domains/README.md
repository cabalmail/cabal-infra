<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 35px; float:left; height: 100%"><img src="../../docs/logo.png" width="35" />
<p><a href="../../README.md">Main documentation</a></p>
</div>


## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_mail_domains"></a> [mail\_domains](#input\_mail\_domains) | n/a | `list(string)` | n/a | yes |
## Modules

No modules.
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_domains"></a> [domains](#output\_domains) | n/a |
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
<!-- END_TF_DOCS -->
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
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | Root domain for infrastructure. | `any` | n/a | yes |
| <a name="input_email"></a> [email](#input\_email) | Contact email for the certificate requester for the certificate API. | `any` | n/a | yes |
| <a name="input_prod"></a> [prod](#input\_prod) | Whether to use the production certificate API. | `any` | n/a | yes |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Route 53 Zone ID for control domain. | `any` | n/a | yes |
# Inputs End
# Modules Start
## Modules

No modules.
# Modules End
# Outputs Start
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cert_arn"></a> [cert\_arn](#output\_cert\_arn) | n/a |
# Outputs End
# Providers Start
## Providers

| Name | Version |
|------|---------|
| <a name="provider_acme"></a> [acme](#provider\_acme) | 2.2.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 3.67.0 |
| <a name="provider_tls"></a> [tls](#provider\_tls) | n/a |
# Providers End
# Requirements Start
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0.0 |
| <a name="requirement_acme"></a> [acme](#requirement\_acme) | 2.2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 3.67.0 |
# Requirements End
# Resources Start
## Resources

| Name | Type |
|------|------|
| [acme_certificate.cert](https://registry.terraform.io/providers/vancluever/acme/2.2.0/docs/resources/certificate) | resource |
| [acme_registration.reg](https://registry.terraform.io/providers/vancluever/acme/2.2.0/docs/resources/registration) | resource |
| [aws_acm_certificate.cert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate) | resource |
| [aws_acm_certificate_validation.cert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) | resource |
| [aws_route53_record.cert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_ssm_parameter.cabal_private_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.cert](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [aws_ssm_parameter.chain](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter) | resource |
| [tls_cert_request.csr](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/cert_request) | resource |
| [tls_private_key.key](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_private_key.pk](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
# Resources End
<!-- END_TF_DOCS -->
<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />
<p><a href="/README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">

Provisions a Let's Encrypt certificate and stores it in System Manager Parameter Store for use by mail servers.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | Root domain for infrastructure. | `string` | n/a | yes |
| <a name="input_email"></a> [email](#input\_email) | Contact email for the certificate requester for the certificate API. | `string` | n/a | yes |
| <a name="input_prod"></a> [prod](#input\_prod) | Whether to use the production certificate API. | `bool` | n/a | yes |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Route 53 Zone ID for control domain. | `string` | n/a | yes |
## Modules

No modules.
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cert_arn"></a> [cert\_arn](#output\_cert\_arn) | ARN of the AWS Certificate Manager certificate. |
## Providers

| Name | Version |
|------|---------|
| <a name="provider_acme"></a> [acme](#provider\_acme) | 2.2.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 3.67.0 |
| <a name="provider_tls"></a> [tls](#provider\_tls) | n/a |
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0.0 |
| <a name="requirement_acme"></a> [acme](#requirement\_acme) | 2.2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 3.67.0 |
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

</div>
<!-- END_TF_DOCS -->
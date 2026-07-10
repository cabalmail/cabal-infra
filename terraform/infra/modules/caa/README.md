<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />
<p><a href="/README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">

Publishes CAA records that authorize only the certificate authorities we
actually use, so no other CA may issue a certificate for our domains.

Both TLS certificates we issue target `*.<control_domain>`: the ACM
certificate (`modules/cert`) and the Let's Encrypt certificate
(`modules/certbot_renewal`). Because those are wildcards, every issuer is
authorized for both `issue` and `issuewild`.

- Control domain: ACM + Let's Encrypt. ACM rotates its issuing
  intermediates by region and service, so all four Amazon CA identifiers are
  authorized to avoid a surprise validation failure.
- Mail domains: ACM only. Let's Encrypt is architecturally control-domain
  only - certbot is hardwired to `CONTROL_DOMAIN` and the mail services
  present control-domain hostnames, so a mail apex never terminates a
  Let's Encrypt certificate. ACM stays authorized as the AWS-native path in
  case a mail domain is ever fronted by an AWS service.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | Root domain for infrastructure. CAA authorizing ACM and Let's Encrypt is published at its apex. | `string` | n/a | yes |
| <a name="input_control_domain_zone_id"></a> [control\_domain\_zone\_id](#input\_control\_domain\_zone\_id) | Route 53 Zone ID for the control domain (owned by the bootstrap terraform/dns stack). | `string` | n/a | yes |
| <a name="input_mail_domains"></a> [mail\_domains](#input\_mail\_domains) | Mail domains and their Route 53 zone IDs (module.domains.domains). Each gets an ACM-only CAA record; the control domain is skipped here as it is covered by control\_domain\_zone\_id. | `list(object({ domain = string, zone_id = string }))` | n/a | yes |
| <a name="input_iodef_email"></a> [iodef\_email](#input\_iodef\_email) | Contact address for the CAA iodef property, where a CA reports requests that violate the policy. The root stack sets this to the Let's Encrypt contact email (var.email). | `string` | n/a | yes |
| <a name="input_ttl"></a> [ttl](#input\_ttl) | TTL in seconds for the CAA records. | `number` | `3600` | no |
## Modules

No modules.
## Outputs

No outputs.
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.32 |
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.1.2 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.32 |
## Resources

| Name | Type |
|------|------|
| [aws_route53_record.control](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_route53_record.mail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |

</div>
<!-- END_TF_DOCS -->

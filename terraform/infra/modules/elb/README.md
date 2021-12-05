<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_lb.elb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb) | resource |
| [aws_lb_listener.imap](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_listener.relay](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_listener.starttls](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_listener.submission](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_target_group.imap](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_lb_target_group.relay](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_lb_target_group.starttls](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_lb_target_group.submission](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_route53_record.cname](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cert_arn"></a> [cert\_arn](#input\_cert\_arn) | n/a | `string` | n/a | yes |
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | Root domain for infrastructure. | `any` | n/a | yes |
| <a name="input_public_subnets"></a> [public\_subnets](#input\_public\_subnets) | Subnets for load balancer targets. | `any` | n/a | yes |
| <a name="input_vpc"></a> [vpc](#input\_vpc) | VPC for the load balancer. | `any` | n/a | yes |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Route 53 Zone ID for control domain | `any` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_imap_tg"></a> [imap\_tg](#output\_imap\_tg) | n/a |
| <a name="output_relay_tg"></a> [relay\_tg](#output\_relay\_tg) | n/a |
| <a name="output_starttls_tg"></a> [starttls\_tg](#output\_starttls\_tg) | n/a |
| <a name="output_submission_tg"></a> [submission\_tg](#output\_submission\_tg) | n/a |
<!-- END_TF_DOCS -->
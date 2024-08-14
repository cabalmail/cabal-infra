<!-- BEGIN_TF_DOCS -->
# Cabalmail
<div style="width: 10em; float:left; height: 100%; padding-right: 1em;"><img src="/docs/logo.png" width="100" />
<p><a href="/README.md">Main documentation</a></p>
</div><div style="padding-left: 11em;">

# Cabalmail infra

This terraform stack stands up AWS infrastructure needed for a Cabalmail system. See [README.md](../../README.md) at the root of this repository for general information.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_availability_zones"></a> [availability\_zones](#input\_availability\_zones) | List of availability zones to use for the primary region. | `list(string)` | <pre>[<br>  "us-west-1a"<br>]</pre> | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region in which to provision primary infrastructure. Default us-west-1. | `string` | `"us-west-1"` | no |
| <a name="input_backup"></a> [backup](#input\_backup) | Whether to create backups of critical data. Defaults to the prod setting. Defaults to false. | `bool` | `false` | no |
| <a name="input_chef_license"></a> [chef\_license](#input\_chef\_license) | Must be the word 'accept' in order to indicate your acceptance of the Chef license. The license text can be viewed here: https://www.chef.io/end-user-license-agreement. | `string` | `"not accepted"` | no |
| <a name="input_cidr_block"></a> [cidr\_block](#input\_cidr\_block) | CIDR block for the VPC in the primary region. | `string` | n/a | yes |
| <a name="input_control_domain"></a> [control\_domain](#input\_control\_domain) | The domain used for naming your email infrastructure. E.g., if you want to host imap.example.com and smtp-out.example.com, then this would be 'example.com'. This domain is not used for email addresses. | `string` | n/a | yes |
| <a name="input_email"></a> [email](#input\_email) | Email for the CSR. | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | A name for your environment such as 'production' or 'staging'. | `string` | n/a | yes |
| <a name="input_imap_scale"></a> [imap\_scale](#input\_imap\_scale) | Minimum, maximum, and desired number of IMAP servers; and size of IMAP servers. IMPORTANT: This stack uses open source Dovecot, which does not support multiple instances accessing the same mailstore over NFS. Since this stack also uses NFS for the mailstore, all three of these numbers should always be set to 1. Defaults to { min = 0, max = 0, des = 0, size = "t2.micro" } in order to prevent unexpected AWS charges. | <pre>object({<br>    min  = number<br>    max  = number<br>    des  = number<br>    size = string<br>  })</pre> | <pre>{<br>  "des": 0,<br>  "max": 0,<br>  "min": 0,<br>  "size": "t2.micro"<br>}</pre> | no |
| <a name="input_mail_domains"></a> [mail\_domains](#input\_mail\_domains) | List of domains from which you want to send mail, and to which you want to allow mail to be sent. Must have at least one. | `list(string)` | n/a | yes |
| <a name="input_prod"></a> [prod](#input\_prod) | Whether to use the production Let's Encrypt service. Default false. | `bool` | `false` | no |
| <a name="input_repo"></a> [repo](#input\_repo) | This repository. Used for resource tagging. | `string` | `"https://github.com/ccarr-cabal/cabal-infra/tree/main"` | no |
| <a name="input_smtpin_scale"></a> [smtpin\_scale](#input\_smtpin\_scale) | Minimum, maximum, and desired number of incoming SMTP servers; and size of incoming SMTP servers. All three numbers should be at least 1, and must satisfy minimum <= desired <= maximum. Defaults to { min = 0, max = 0, des = 0, size = "t2.micro" } in order to prevent unexpected AWS charges. | <pre>object({<br>    min  = number<br>    max  = number<br>    des  = number<br>    size = string<br>  })</pre> | <pre>{<br>  "des": 0,<br>  "max": 0,<br>  "min": 0,<br>  "size": "t2.micro"<br>}</pre> | no |
| <a name="input_smtpout_scale"></a> [smtpout\_scale](#input\_smtpout\_scale) | Minimum, maximum, and desired number of outgoing SMTP servers; and size of outgoing SMTP servers. All three numbers should be at least 1, and must satisfy minimum <= desired <= maximum. Defaults to { min = 0, max = 0, des = 0, size = "t2.micro" } in order to prevent unexpected AWS charges. | <pre>object({<br>    min  = number<br>    max  = number<br>    des  = number<br>    size = string<br>  })</pre> | <pre>{<br>  "des": 0,<br>  "max": 0,<br>  "min": 0,<br>  "size": "t2.micro"<br>}</pre> | no |
## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_admin"></a> [admin](#module\_admin) | ./modules/app | n/a |
| <a name="module_backup"></a> [backup](#module\_backup) | ./modules/backup | n/a |
| <a name="module_bucket"></a> [bucket](#module\_bucket) | ./modules/s3 | n/a |
| <a name="module_cert"></a> [cert](#module\_cert) | ./modules/cert | n/a |
| <a name="module_domains"></a> [domains](#module\_domains) | ./modules/domains | n/a |
| <a name="module_efs"></a> [efs](#module\_efs) | ./modules/efs | n/a |
| <a name="module_imap"></a> [imap](#module\_imap) | ./modules/asg | n/a |
| <a name="module_lambda_layers"></a> [lambda\_layers](#module\_lambda\_layers) | ./modules/lambda_layers | n/a |
| <a name="module_load_balancer"></a> [load\_balancer](#module\_load\_balancer) | ./modules/elb | n/a |
| <a name="module_pool"></a> [pool](#module\_pool) | ./modules/user_pool | n/a |
| <a name="module_smtp_in"></a> [smtp\_in](#module\_smtp\_in) | ./modules/asg | n/a |
| <a name="module_smtp_out"></a> [smtp\_out](#module\_smtp\_out) | ./modules/asg | n/a |
| <a name="module_table"></a> [table](#module\_table) | ./modules/table | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | ./modules/vpc | n/a |
## Outputs

| Name | Description |
|------|-------------|
| <a name="output_IMPORTANT"></a> [IMPORTANT](#output\_IMPORTANT) | Instructions for post-automation steps. |
| <a name="output_domains"></a> [domains](#output\_domains) | Nameservers to be added to your domain registrations. |
| <a name="output_relay_ips"></a> [relay\_ips](#output\_relay\_ips) | IP addresses that will be used for outbound mail. See README.md section on PTR records for important instructions. |
## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.32 |
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.1.2 |
| <a name="requirement_acme"></a> [acme](#requirement\_acme) | 2.2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.32 |
## Resources

| Name | Type |
|------|------|
| [aws_ssm_parameter.zone](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

</div>
<!-- END_TF_DOCS -->
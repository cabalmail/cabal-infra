# Plan: Replace ACME Terraform Provider with Certbot Lambda

## Context

The cert module (`terraform/infra/modules/cert/`) currently uses two parallel certificate paths:
1. **ACM certificate** (`main.tf`) — wildcard `*.control_domain`, DNS-validated, used by NLB/CloudFront. This stays.
2. **ACME/Let's Encrypt certificate** (`acme.tf`) — uses the `vancluever/acme` Terraform provider to issue a cert via DNS-01 challenge and store the key, cert, and chain in SSM Parameter Store. ECS containers (and legacy ASG instances) consume these SSM values.

The ACME approach is problematic: certs expire every 90 days and renewal requires `terraform apply`. With the move to ECS containers (branch `0.4.1`), we'll replace this with a **certbot Lambda** that auto-renews and restarts ECS services.

## Approach: Container-image Lambda on EventBridge Schedule

- A Python Lambda (packaged as a Docker container image) runs certbot with the `certbot-dns-route53` plugin
- EventBridge triggers it every 60 days
- After obtaining/renewing the cert, it writes to the same SSM paths and forces new ECS deployments
- No VPC placement needed (certbot + SSM + ECS APIs are all public endpoints)

---

## Files to Delete

| File | Reason |
|------|--------|
| `terraform/infra/modules/cert/acme.tf` | Entire ACME provider approach replaced |

## Files to Modify

| File | Change |
|------|--------|
| `terraform/infra/modules/cert/versions.tf` | Remove `acme` and `tls` provider requirements |
| `terraform/infra/modules/cert/variables.tf` | Remove `prod` and `email` variables (only used by ACME) |
| `terraform/infra/main.tf` | Remove `prod`/`email` from cert module call; add `certbot_renewal` module |

## New Files to Create

### Terraform module: `terraform/infra/modules/certbot_renewal/`

| File | Purpose |
|------|---------|
| `versions.tf` | AWS provider requirement |
| `variables.tf` | `control_domain`, `zone_id`, `email`, `prod`, `region`, `ecs_cluster_name`, `ecs_service_arns` |
| `ecr.tf` | ECR repo `cabal/certbot-renewal` with lifecycle policy (keep last 3 images) |
| `iam.tf` | Lambda execution role with policies for: Route 53 (DNS challenge), SSM PutParameter (cert storage), ECS UpdateService (restart), CloudWatch Logs |
| `lambda.tf` | Container-image Lambda (`cabal-certbot-renewal`), 5 min timeout, 512 MB, arm64, log group |
| `schedule.tf` | EventBridge Scheduler rule (`rate(60 days)`), scheduler IAM role |
| `outputs.tf` | `lambda_function_name`, `ecr_repository_url` |

### Lambda code and Docker image: `lambda/certbot-renewal/`

| File | Purpose |
|------|---------|
| `Dockerfile` | Based on `public.ecr.aws/lambda/python:3.13-arm64`, installs `certbot`, `certbot-dns-route53`, `boto3` |
| `handler.py` | Lambda handler: runs certbot via subprocess, reads generated cert files, writes to SSM (`/cabal/control_domain_ssl_key`, `/cabal/control_domain_ssl_cert`, `/cabal/control_domain_chain_cert`), forces new ECS deployments |

This lives under `lambda/` (not `docker/`) so that all Lambda functions remain in one place. The `docker/` directory is reserved for the mail tier containers and their shared resources.

### CI workflow update: `.github/workflows/docker.yml`

Add `certbot-renewal` to the build matrix so the image is built and pushed alongside the mail tier images. The certbot image build context is `lambda/certbot-renewal/` (self-contained, unlike the mail tiers which use `docker/` as context).

---

## Implementation Details

### handler.py logic
1. Run `certbot certonly --dns-route53 --domains *.{control_domain}` in `/tmp`
2. Read `privkey.pem`, `cert.pem`, `chain.pem` from certbot's output
3. `ssm.put_parameter(Overwrite=True)` for each of the 3 SSM paths
4. `ecs.update_service(forceNewDeployment=True)` for each ECS service (if configured)
5. Use `--staging` flag when `USE_STAGING=true` (maps to `var.prod`)

### IAM permissions for the Lambda role
- `route53:GetChange`, `route53:ChangeResourceRecordSets`, `route53:ListResourceRecordSets` on the hosted zone
- `route53:ListHostedZones`, `route53:ListHostedZonesByName` on `*` (required by certbot-dns-route53)
- `ssm:PutParameter`, `ssm:GetParameter` on the 3 specific `/cabal/*` parameters
- `ecs:UpdateService`, `ecs:DescribeServices` on the ECS service ARNs
- `logs:CreateLogStream`, `logs:PutLogEvents` on the log group

### Wiring in main.tf
```hcl
module "certbot_renewal" {
  source           = "./modules/certbot_renewal"
  control_domain   = var.control_domain
  zone_id          = data.aws_ssm_parameter.zone.value
  email            = var.email
  prod             = var.prod
  region           = var.aws_region
  ecs_cluster_name = module.ecs.cluster_name
  ecs_service_arns = [
    "arn:aws:ecs:${var.aws_region}:ACCOUNT:service/${module.ecs.cluster_name}/${module.ecs.imap_service_name}",
    "arn:aws:ecs:${var.aws_region}:ACCOUNT:service/${module.ecs.cluster_name}/${module.ecs.smtp_in_service_name}",
    "arn:aws:ecs:${var.aws_region}:ACCOUNT:service/${module.ecs.cluster_name}/${module.ecs.smtp_out_service_name}",
  ]
}
```
(Will use `data.aws_caller_identity` for the account ID rather than a literal.)

---

## Pre-deployment: Terraform State Migration

Before applying, remove the ACME-managed resources from state so they aren't destroyed:

```bash
terraform state rm 'module.cert.aws_ssm_parameter.cabal_private_key'
terraform state rm 'module.cert.aws_ssm_parameter.cert'
terraform state rm 'module.cert.aws_ssm_parameter.chain'
terraform state rm 'module.cert.acme_certificate.cert'
terraform state rm 'module.cert.acme_registration.reg'
terraform state rm 'module.cert.tls_private_key.key'
terraform state rm 'module.cert.tls_private_key.pk'
terraform state rm 'module.cert.tls_cert_request.csr'
```

---

## Verification

1. **`terraform plan`** after state removal — should show ACME resources as gone (already removed), new certbot_renewal resources as additions, no SSM parameter destruction
2. **`terraform apply`** — creates ECR repo, Lambda, EventBridge schedule, IAM
3. **Build and push** the certbot Docker image to ECR
4. **Update Lambda function code** to point to the pushed image
5. **Manual test invocation**: `aws lambda invoke --function-name cabal-certbot-renewal --payload '{}' /dev/stdout`
6. **Verify SSM updated**: `aws ssm get-parameter --name "/cabal/control_domain_ssl_cert" --query 'Parameter.LastModifiedDate'`
7. **Verify ECS restart**: check that ECS services show a new deployment after the Lambda runs

# Quiesce: scale a non-prod environment to zero

The `quiesce` workflow scales a development or stage environment's running compute to zero so it stops accruing hourly charges. Mail data, address data, and other state-bearing resources are left alone, so the environment can be brought back up with a single workflow run.

## What gets quiesced

| Resource | Behavior when quiesced |
|---|---|
| ECS services for `imap`, `smtp-in`, `smtp-out` | `desired_count = 0` |
| ECS services for the monitoring stack (Prometheus, Alertmanager, Grafana, Uptime Kuma, Healthchecks, ntfy, cloudwatch-exporter, blackbox-exporter) | `desired_count = 0` |
| ECS Application Auto Scaling targets for `smtp-in` and `smtp-out` | `min_capacity = 0`, `max_capacity = 0` |
| ECS-instance Auto Scaling Group | `min_size = 0`, `desired_capacity = 0`, `max_size = 0` |
| ASG instance scale-in protection (`protect_from_scale_in`) | Disabled, so the running instance can actually be terminated |
| ECS capacity provider `managed_termination_protection` | Disabled, so the capacity provider stops fighting the ASG drain |
| NAT instances | `count = 0`. The Elastic IPs are kept, so SMTP allow-lists do not need to be re-issued on resume. |
| Private subnet default route | Removed. The NAT-instance NIC it pointed to is gone, and nothing runs in private subnets while quiesced. |

The DAEMON `node-exporter` ECS service is not gated explicitly. It places one task per EC2 instance in the cluster; with the ASG at zero, it has no instances to schedule on and naturally goes to zero with the rest of the compute.

## What is preserved

- DynamoDB tables (`cabal-addresses`, `cabal-user-preferences`, `cabal-dmarc-reports`, the Cognito counter table)
- EFS file system and mount targets (the mailstore and monitoring persistence volumes)
- S3 buckets (React app, Lambda artifacts)
- Cognito user pool and clients
- Route 53 zones, records, and the EIP-keyed `smtp.<control-domain>` record
- ACM certificate
- The Network Load Balancer and its target groups
- The CloudFront distribution
- All Lambda functions (API, certbot-renewal, DMARC ingest, alert sink), their event sources, and SSM-stored config

A quiesced environment will fail TCP health checks on IMAP/SMTP and serve no monitoring UI. DNS still resolves; clients see connection timeouts rather than NXDOMAIN.

## Running the workflow

The workflow is in [.github/workflows/quiesce.yml](../../.github/workflows/quiesce.yml). It is `workflow_dispatch` only.

1. Switch to the branch that maps to your target environment (`stage` for the `stage` environment, anything else for `development`). The `main` branch is rejected outright.
2. From the GitHub Actions UI, run **Quiesce Infrastructure** with:
   - `environment` = `development` or `stage`
   - `action` = `down` to scale to zero, or `up` to restore
3. The job validates that the branch matches the chosen environment, generates the same backend config and tfvars that `infra.yml` does, and runs `terraform apply` with `quiesced = true|false` written directly into the tfvars file.

## Durability across other Terraform runs

`infra.yml` runs on any push that touches `terraform/infra/**` (or `terraform/dns/**`) and on `workflow_dispatch`. It writes `quiesced = ${{ vars.TF_VAR_QUIESCED || 'false' }}` to its tfvars, so by default it un-quiesces.

To keep an environment quiesced across other runs:

- After running `quiesce` with `action: down`, set `TF_VAR_QUIESCED=true` on the matching GitHub Environment (`development` or `stage`) under **Settings -> Environments**.
- After running `quiesce` with `action: up`, clear `TF_VAR_QUIESCED` (set to `false` or remove the variable).

Forgetting this step is recoverable: the next `infra.yml` run will simply restore compute. The state-bearing resources are unaffected either way.

## Caveats

- Resume time is bounded by EC2 instance bootstrap and ECS task startup. Expect a few minutes before mail tiers are healthy again.
- Active connections to `imap.<control-domain>` and `smtp.<control-domain>` are dropped at the NLB once tasks deregister.
- Alarms wired to `UnHealthyHostCount` on the NLB target groups will fire continuously while quiesced. This is expected; suppress or accept the noise on non-prod.
- The NLB itself is not torn down. It costs roughly $16/month idle. Tearing it down was considered but rejected for v1: it triggers Route 53 alias re-resolution on resume and adds non-trivial cascade.
- The monitoring ALB is also kept up when `monitoring = true`. Same rationale.
- The certbot-renewal Lambda continues to run on its 60-day schedule and will renew certificates while the environment is quiesced. This is intentional - it avoids cert expiry during long quiesce periods.

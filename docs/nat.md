# NAT and private-subnet egress

Cabalmail runs its mail tiers (and the Image Builder build instances) in private
subnets. Their only path to the internet and to AWS service APIs is through the
VPC's NAT. This document covers how NAT is configured, how to stand it up in a
new environment, and how to diagnose the one failure mode that takes the whole
data plane down with it.

## Why this matters more than usual

**There are no VPC endpoints.** Every call a private-subnet container makes -
DynamoDB, S3, SSM, ECR, Cognito, SQS/SNS, CloudWatch Logs, and outbound SMTP on
port 25 - egresses through the NAT. If NAT egress breaks, all of the following
break at once, even though the instances keep "running":

- Outbound mail delivery stalls (sendmail cannot reach recipient MX servers).
- The `/send` Lambda hangs and times out (its submission to `smtp-out` blocks on
  `smtp-out`'s now-unreachable outbound delivery).
- Container logs stop shipping to CloudWatch (the `awslogs` driver cannot reach
  the Logs endpoint), so the tiers go silent in CloudWatch.
- The live-reconfigure path, DMARC ingest, and anything else touching a service
  API begins to fail.

Treat any "NAT instance replaced" line in a Terraform plan as a brief egress
outage and apply it in a maintenance window.

## How NAT is wired

NAT instances (not a NAT Gateway) are used in every deployed environment
(`use_nat_instance = true` in the `vpc` module block of
[terraform/infra/main.tf](../terraform/infra/main.tf)). The relevant resources
live in [terraform/infra/modules/vpc/nat.tf](../terraform/infra/modules/vpc/nat.tf):

- One Elastic IP per AZ (`aws_eip.nat_eip`). These are the **stable outbound
  source IPs** for mail. The public `smtp.<control-domain>` A record points at
  them, and they are what you allow-list for the port-25 block (see below) and
  what your SPF records authorize. The EIPs are preserved across quiesce so
  allow-lists never need re-issuing.
- One NAT instance per AZ, with `source_dest_check = false`, in the public
  subnets, each the `0.0.0.0/0` target of its AZ's private route table.

| Variable | Where | Default | Purpose |
|---|---|---|---|
| `use_nat_instance` | `vpc` module block (main.tf) | `true` | NAT instances vs. NAT Gateway. Deployed environments use instances. |
| `nat_instance_type` | `vpc` module var | `t3.micro` | NAT instance size. **x86_64** - the custom-AMI pipeline matches this arch. |
| `region` | `vpc` module var (from `var.aws_region`) | n/a | Used to build the Image Builder managed-image ARN. |
| `use_custom_nat_ami` | root + `vpc` module var | `false` | Stock AL2 AMI (`false`) vs. the baked custom AL2023 AMI (`true`). See below. |
| `quiesced` | root + `vpc` module var | `false` | Scales NAT instances to zero (non-prod cost saving). See [quiesce.md](./quiesce.md). |

## AMI choice: stock AL2 vs. custom AL2023

The NAT instance needs a userspace firewall tool to install the masquerade
(SNAT) rule that makes it a NAT. There are two paths:

- **Stock Amazon Linux 2 (`use_custom_nat_ami = false`, the default).** AL2
  preinstalls `iptables`, so the instance's `user_data` lays down the masquerade
  rule at boot with no package install. Proven and self-contained.
- **Custom Amazon Linux 2023 (`use_custom_nat_ami = true`).** AL2023's base AMI
  ships **no** firewall tool (neither `nftables` nor `iptables`), so a boot-time
  install is fragile - it broke all egress in 0.10.1 when the install step
  failed silently. Instead, an EC2 Image Builder pipeline
  ([nat_ami.tf](../terraform/infra/modules/vpc/nat_ami.tf) +
  [nat-nftables-component.yaml](../terraform/infra/modules/vpc/nat-nftables-component.yaml))
  **bakes** `nftables`, the masquerade ruleset, `ip_forward`, and an enabled
  `nftables.service` into a custom AMI. Instances launched from it come up as a
  working NAT with no boot-time install.

New environments and the AL2 -> AL2023 migration both follow the same two-phase
bootstrap below, because the custom AMI does not exist until the pipeline has
run once.

## Setting up NAT in a new environment

> A "new environment" is a new AWS account / GitHub Environment / branch with its
> own `infra` Terraform state.

### 1. Provision the stack (NAT comes up on stock AL2)

A normal `infra` apply creates the VPC, the NAT EIPs, the NAT instances (on the
stock AL2 AMI, since `use_custom_nat_ami` defaults to `false`), **and** the
Image Builder pipeline. No special action is needed for the NAT instances
themselves at this stage.

### 2. Verify egress (see "Verifying egress" below)

Confirm private-subnet egress works before doing anything else - the rest of the
mail system depends on it.

### 3. Clear the port-25 block

The `relay_ips` output lists your NAT EIPs. AWS blocks outbound port 25 by
default; request removal via the [rdns-limits form](https://console.aws.amazon.com/support/contacts?#/rdns-limits).
See [Post-Automation Steps in setup.md](./setup.md#PostAutomation).

### 4. (Recommended) Move to the custom AL2023 AMI

This is the permanent, patchable AL2023 path. Do it deliberately, in a window,
because it replaces the NAT instances.

1. **Trigger the first build.** Wait for the daily schedule, or run it now:
   ```
   aws imagebuilder start-image-pipeline-execution \
     --image-pipeline-arn "$(aws imagebuilder list-image-pipelines \
       --query "imagePipelineList[?name=='cabal-nat-al2023'].arn | [0]" --output text)"
   ```
   The build/test instances run in a private subnet behind the (working) AL2
   NAT, so this needs egress to already be up - which it is after step 2.
2. **Confirm the AMI exists.** Wait ~15-20 min, then check an AMI named
   `cabal-nat-al2023-*` is available:
   ```
   aws ec2 describe-images --owners self \
     --filters "Name=name,Values=cabal-nat-al2023-*" \
     --query 'reverse(sort_by(Images,&CreationDate))[].[Name,ImageId,State]' --output table
   ```
3. **Flip the toggle.** Set `use_custom_nat_ami = true` (via
   `TF_VAR_use_custom_nat_ami`, the same mechanism as `TF_VAR_MONITORING`).
4. **Apply in a window.** The plan will show `aws_instance.nat` being replaced.
   Approve it; egress drops briefly per AZ while the instances recreate.
5. **Re-verify egress.**

From here it is hands-off: the pipeline rebuilds only when the AL2023 base image
has updates, and each rebuild surfaces as a NAT replacement in the next plan for
you to approve.

## Verifying egress

- NAT instances are `running`, one per AZ:
  ```
  aws ec2 describe-instances --filters "Name=tag:Name,Values=cabal-nat-*" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,State.Name]' --output table
  ```
- Each private route table's `0.0.0.0/0` points at a NAT instance ENI
  (`aws ec2 describe-route-tables`).
- The mail tiers are shipping logs **recently** - the most reliable end-to-end
  egress signal, since CloudWatch Logs has no VPC endpoint:
  ```
  aws logs describe-log-streams --log-group-name /ecs/cabal-smtp-out \
    --order-by LastEventTime --descending --max-items 1 \
    --query 'logStreams[0].lastEventTimestamp'
  ```
  A timestamp within the last few minutes means egress is healthy. A timestamp
  frozen at some point in the past is the classic broken-egress symptom.
- NLB target groups for `imap`/`smtp-in`/`smtp-out` are healthy, and a test send
  completes in ~2-3 s (not 30-60 s).

## How the custom-AMI pipeline rebuilds (patching)

The pipeline (`cabal-nat-al2023`) checks daily and builds **only when the AL2023
base image actually has an update**
(`EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE`), so it tracks AL2023
security patches without churning no-op images. Builds are asynchronous and do
**not** roll the NAT on their own: `nat.tf` reads the latest AMI via
`data.aws_ami.custom_nat` (`owners = ["self"]`, `most_recent = true`), so a fresh
build appears as a NAT replacement in the next plan and is adopted only when you
deliberately apply it. To force an off-schedule rebuild (e.g. an urgent CVE), run
the `start-image-pipeline-execution` command from step 4 above.

Changing the bootstrap itself (the component YAML) requires bumping the
`version` on `aws_imagebuilder_component.nat_nftables` and
`aws_imagebuilder_image_recipe.nat` in `nat_ami.tf` - Image Builder component and
recipe versions are immutable.

## Troubleshooting: egress is down

Symptoms (this is exactly the 0.10.1 incident): sends time out at the `/send`
Lambda; outbound mail queues instead of delivering; the mail tiers go silent in
CloudWatch (logs stop shipping because the `awslogs` driver can't reach the Logs
endpoint); private-subnet API calls hang.

1. **Confirm it's egress.** Check whether the tiers stopped logging at roughly
   the same moment (the "Verifying egress" log-timestamp check). Simultaneous
   silence across tiers = shared NAT egress failure, not an app bug.
2. **Read the NAT instance boot log** for a failed bootstrap:
   ```
   aws ec2 get-console-output --instance-id <nat-instance-id> --latest \
     --query 'Output' --output text | grep -iE "nftables|iptables|forward|fail|error"
   ```
   `Unit file nftables.service does not exist` or a `dnf` failure means the
   masquerade rule never loaded - the instance is forwarding without SNAT.
3. **Immediate mitigation** (the running instance has its EIP, so it can reach
   the internet itself). On each NAT instance, via SSM Session Manager:
   ```
   sudo dnf install -y nftables
   sudo nft -f /etc/nftables/cabal-nat.nft
   grep -q cabal-nat.nft /etc/sysconfig/nftables.conf || \
     echo 'include "/etc/nftables/cabal-nat.nft"' | sudo tee -a /etc/sysconfig/nftables.conf
   sudo systemctl enable --now nftables && sudo nft list ruleset
   ```
   (On a stock AL2 instance the equivalent is restoring the iptables rules; see
   the `user_data` in `nat.tf`.)
4. **Rollback lever.** If a freshly baked custom AMI is the culprit, set
   `use_custom_nat_ami = false` and apply to return the NAT instances to the
   proven stock AL2 bootstrap.

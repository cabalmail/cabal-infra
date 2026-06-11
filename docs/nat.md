# NAT and private-subnet egress

Cabalmail runs its mail tiers (and the Image Builder build instances) in private
subnets. Their only path to the internet and to AWS service APIs is through the
VPC's NAT. This document covers the two supported NAT modes, how to stand
either one up in a new environment, and how to diagnose the one failure mode
that takes the whole data plane down with it.

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

## The two modes

NAT runs in one of two first-class, indefinitely supported modes, selected per
environment by `use_nat_instance` (a GitHub Environment variable,
`TF_VAR_USE_NAT_INSTANCE`, echoed into tfvars by `infra.yml`; defaults to
`true`):

| Mode | `use_nat_instance` | What | Who it's for |
|---|---|---|---|
| **NAT instances** | `true` (default) | One EC2 instance per AZ from a custom AL2023 AMI baked by EC2 Image Builder | Cheapest; small / personal / family deployments (the current prod + stage choice) |
| **NAT Gateway** | `false` | One AWS-managed NAT Gateway per AZ; no AMI, no OS | Commercial / at-scale operators, or anyone preferring managed over cheap |

Approximate us-east-1 monthly cost (the reason instances are the small-scale
default): 2x t3.micro instances ~$15 (no per-GB); 1 NAT Gateway ~$33 +
~$0.045/GB; 2 NAT Gateways (per-AZ HA) ~$65 + per-GB. At four-user scale a
gateway is roughly half the run-rate; at commercial volume the managed
reliability wins.

**Both modes reuse the same Elastic IPs** (`aws_eip.nat_eip`, one per AZ).
These are the stable outbound source IPs for mail: the public
`smtp.<control-domain>` A record points at them, they are what you allow-list
for the port-25 block (see below), and they are what your SPF records
authorize. Switching modes does not change them, and they are preserved across
quiesce, so allow-lists never need re-issuing.

## How NAT is wired

The resources live in
[terraform/infra/modules/vpc/nat.tf](../terraform/infra/modules/vpc/nat.tf):

- One Elastic IP per AZ (`aws_eip.nat_eip`), shared by both modes.
- **Instance mode:** one NAT instance per AZ, launched from the latest baked
  `cabal-nat-al2023-*` AMI, with `source_dest_check = false`, in the public
  subnets, each the `0.0.0.0/0` target of its AZ's private route table.
- **Gateway mode:** one `aws_nat_gateway` per AZ in the public subnets, holding
  the same EIPs, each the `0.0.0.0/0` target of its AZ's private route table.

| Variable | Where | Default | Purpose |
|---|---|---|---|
| `use_nat_instance` | root + `vpc` module var (`TF_VAR_USE_NAT_INSTANCE`) | `true` | NAT instances vs. NAT Gateways. See "The two modes". |
| `build_nat_ami` | root + `vpc` module var (`TF_VAR_BUILD_NAT_AMI`) | `true` | Whether the Image Builder pipeline that bakes the NAT AMI exists. Independent of the egress mode; set `false` only in a pure-gateway environment that will never run instances. |
| `nat_instance_type` | `vpc` module var | `t3.micro` | NAT instance size. **x86_64** - the custom-AMI pipeline matches this arch. |
| `region` | `vpc` module var (from `var.aws_region`) | n/a | Used to build the Image Builder managed-image ARN. |
| `quiesced` | root + `vpc` module var | `false` | Scales NAT (instances or gateways) to zero (non-prod cost saving). EIPs are kept. See [quiesce.md](./quiesce.md). |

## The NAT instance AMI

A NAT instance needs a userspace firewall tool to install the masquerade
(SNAT) rule that makes it a NAT, and AL2023's base AMI ships none (neither
`nftables` nor `iptables`) - a boot-time install is fragile and broke all
egress in 0.10.1 when the install step failed silently. So instance mode
*always* launches from a custom AMI: an EC2 Image Builder pipeline
([nat_ami.tf](../terraform/infra/modules/vpc/nat_ami.tf) +
[nat-nftables-component.yaml](../terraform/infra/modules/vpc/nat-nftables-component.yaml))
bakes `nftables`, the masquerade ruleset, `ip_forward`, and an enabled
`nftables.service` into an image named `cabal-nat-al2023-*`. Instances launched
from it come up as a working NAT with no boot-time install.

The chicken-and-egg this creates - the pipeline's build instance needs egress,
but instance-mode egress needs the AMI the pipeline produces - is resolved by
bootstrapping a new instance-mode environment through a NAT Gateway (below).

`data.aws_ami.custom_nat` (the lookup the NAT instances launch from) hard-fails
when no `cabal-nat-al2023-*` AMI exists. That error is deliberate: it is the
guard that stops you flipping an environment to instance mode before the first
AMI has been built.

## Setting up NAT in a new environment

> A "new environment" is a new AWS account / GitHub Environment / branch with
> its own `infra` Terraform state.

### Gateway mode

Set `TF_VAR_USE_NAT_INSTANCE = false` on the GitHub Environment and apply.
There is no step two; the gateways and routes come up in the first apply.
Optionally set `TF_VAR_BUILD_NAT_AMI = false` as well if the environment will
never run NAT instances, to skip building an AMI it will never use.

Then clear the port-25 block (step 3 below).

### Instance mode (bootstraps through a gateway)

A fresh environment has no custom NAT AMI yet, so it cannot start on
instances. Bootstrap is a deliberate double-apply:

1. **Apply 1 - gateway egress.** Set `TF_VAR_USE_NAT_INSTANCE = false` and let
   `infra.yml` apply. NAT Gateways provide egress; the Image Builder pipeline
   (present because `build_nat_ami` defaults to `true`) can now reach the
   internet through them.
2. **Build the first AMI.** Trigger the pipeline (or wait for its daily
   schedule):
   ```
   aws imagebuilder start-image-pipeline-execution \
     --image-pipeline-arn "$(aws imagebuilder list-image-pipelines \
       --query "imagePipelineList[?name=='cabal-nat-al2023'].arn | [0]" --output text)"
   ```
   Wait ~15-20 min, then confirm an AMI named `cabal-nat-al2023-*` is
   `available` **and carries the `Role=cabal-nat` tag** (the tag is applied
   only after the build's test stage passes, so it is the signal that the
   image is actually usable):
   ```
   aws ec2 describe-images --owners self \
     --filters "Name=name,Values=cabal-nat-al2023-*" "Name=tag:Role,Values=cabal-nat" \
     --query 'reverse(sort_by(Images,&CreationDate))[].[Name,ImageId,State]' --output table
   ```
3. **Apply 2 - flip to instances.** Set `TF_VAR_USE_NAT_INSTANCE = true` and
   apply. Terraform creates the NAT instances from the new AMI, repoints the
   private routes at them, and destroys the gateways. Expect a brief per-AZ
   egress blip while the EIPs move; for a bootstrap (nothing running yet) this
   is a non-event, but for a mode switch on a live environment do it in a
   window.

### 3. Clear the port-25 block (both modes)

The `relay_ips` output lists your NAT EIPs. AWS blocks outbound port 25 by
default; request removal via the [rdns-limits form](https://console.aws.amazon.com/support/contacts?#/rdns-limits).
See [Post-Automation Steps in setup.md](./setup.md#PostAutomation). Because
both modes use the same EIPs, this never needs redoing - including across mode
switches.

### 4. Verify egress (both modes)

See "Verifying egress" below. Confirm private-subnet egress works before
relying on anything else - the rest of the mail system depends on it.

## Switching modes on a live environment

Either direction is a single variable flip (`TF_VAR_USE_NAT_INSTANCE`) and an
apply in a maintenance window; expect a few minutes of egress loss per AZ while
the EIPs and routes move. Instances -> gateway needs nothing else. Gateway ->
instances requires a `cabal-nat-al2023-*` AMI to exist (build one through the
gateway first, exactly like bootstrap step 2); the `data.aws_ami.custom_nat`
hard-error stops the apply if you forget.

Gateway mode is also the rollback path if the NAT instances themselves are
misbehaving (e.g. a bad AMI build): flip to the gateway, fix or rebuild the
AMI, flip back.

## Verifying egress

- In instance mode, NAT instances are `running`, one per AZ:
  ```
  aws ec2 describe-instances --filters "Name=tag:Name,Values=cabal-nat-*" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,State.Name]' --output table
  ```
  In gateway mode, the gateways are `available`:
  ```
  aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
    --query 'NatGateways[].[NatGatewayId,SubnetId,State]' --output table
  ```
- Each private route table's `0.0.0.0/0` points at a NAT instance ENI (instance
  mode) or a NAT gateway (gateway mode): `aws ec2 describe-route-tables`.
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
the `start-image-pipeline-execution` command from the bootstrap steps above.

The build and test instances run in a private subnet, so a rebuild needs
healthy egress (either mode) - if egress is down the build fails and the
last-good AMI stays in place, a safe no-op.

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
2. **Read the NAT instance boot log** (instance mode) for a failed bootstrap:
   ```
   aws ec2 get-console-output --instance-id <nat-instance-id> --latest \
     --query 'Output' --output text | grep -iE "nftables|forward|fail|error"
   ```
   `Unit file nftables.service does not exist` or a missing masquerade rule
   means the AMI bake is bad - the instance is forwarding without SNAT.
3. **Immediate mitigation** (the running instance has its EIP, so it can reach
   the internet itself). On each NAT instance, via SSM Session Manager:
   ```
   sudo dnf install -y nftables
   sudo nft -f /etc/nftables/cabal-nat.nft
   grep -q cabal-nat.nft /etc/sysconfig/nftables.conf || \
     echo 'include "/etc/nftables/cabal-nat.nft"' | sudo tee -a /etc/sysconfig/nftables.conf
   sudo systemctl enable --now nftables && sudo nft list ruleset
   ```
4. **Rollback lever.** If the NAT instances (or a freshly adopted AMI) are the
   culprit, flip the environment to gateway mode (`TF_VAR_USE_NAT_INSTANCE =
   false`) and apply: managed gateways restore egress on the same EIPs with no
   AMI in the path. Rebuild or fix the AMI, then flip back in a window.

## History

Instance mode originally bootstrapped on stock Amazon Linux 2 (which
preinstalls `iptables`) behind a `use_custom_nat_ami` toggle, with the custom
AL2023 AMI as a second step. The AL2 path was retired in 0.10.x - AL2 is EOL,
and routing the bootstrap through a NAT Gateway removed the need for any
stock-AMI NAT at all. See
[docs/0.10.x/nat-gateway-bootstrap-plan.md](./0.10.x/nat-gateway-bootstrap-plan.md)
for the plan that drove this.

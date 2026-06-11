# Plan: route the NAT-instance bootstrap through a NAT Gateway (retire AL2)

**Status: implemented (0.10.x).** Kept as the historical planning record. The
operator-facing guide is [docs/nat.md](../nat.md).

## Goal

Make NAT instances and a NAT Gateway **two first-class, indefinitely-supported
deployment modes**, selected per environment, and change the instance-mode
**bootstrap to pass through a NAT Gateway instead of Amazon Linux 2** (which is
EOL). After this, AL2 is gone from the stack entirely.

## The two modes

| Mode | What | Who it's for |
|---|---|---|
| **NAT instances** | Custom AL2023 AMI built by EC2 Image Builder | Cheapest; small / personal / family deployments (the current prod + stage choice) |
| **NAT Gateway** | AWS-managed, no AMI/OS | Commercial / at-scale operators, or anyone preferring managed over cheap |

Approximate us-east-1 monthly cost (the reason instances are the small-scale
default): 2x t3.micro instances ~$15 (no per-GB); 1 NAT Gateway ~$33 +
~$0.045/GB; 2 NAT Gateways (per-AZ HA) ~$65 + per-GB. At four-user scale a
gateway is roughly half the run-rate; at commercial volume the managed
reliability wins.

Both modes reuse the existing `aws_eip.nat_eip` addresses, so
`smtp.<control-domain>`, SPF, and the port-25 allow-list are identical either
way.

## Why route the bootstrap through a gateway

A fresh instance-mode environment has no custom AMI yet, so it needs egress to
build the first one. Today that egress comes from **stock AL2 instances**
(`use_custom_nat_ami = false`), which keeps an EOL dependency in the bootstrap
path. A NAT Gateway gives that egress with no AMI, no OS, and no firewall config
to get wrong - so it is the natural bootstrap base and removes AL2 completely.

## The new double-apply (instance-mode bootstrap)

1. **Apply 1 - `use_nat_instance = false`.** A NAT Gateway provides egress. The
   Image Builder pipeline exists (now decoupled from `use_nat_instance`) and
   builds the AL2023 AMI.
2. **Build the AMI.** Trigger the pipeline; wait for a `cabal-nat-al2023-*` image
   `available` and carrying the `Role=cabal-nat` tag.
3. **Apply 2 - `use_nat_instance = true`.** Terraform creates the AL2023 NAT
   instances from the latest custom AMI, destroys the NAT Gateway, and repoints
   the private routes. Brief per-AZ egress blip - do it in a window.

A **gateway-mode** environment simply stays at `use_nat_instance = false`
forever (and can set the build flag below to `false` to skip building an AMI it
will never use).

## Required changes

1. **`use_nat_instance` becomes an operator variable wired through `infra.yml`.**
   It is hardcoded `true` in the `vpc` module block of `main.tf` today. Make it a
   root + module variable and echo it into `terraform.tfvars` in **both** the
   plan and apply blocks of `.github/workflows/infra.yml`
   (`use_nat_instance = ${{ vars.TF_VAR_USE_NAT_INSTANCE || 'true' }}`).
   - **Default `true`** so existing environments (which won't have the GitHub var
     set) keep their current instance mode. A new environment's admin explicitly
     sets it `false` to start the gateway bootstrap.
   - Reminder: the workflow builds tfvars by echoing each `vars.TF_VAR_*`; a
     variable that isn't echoed there is silently ignored (this bit us once with
     `use_custom_nat_ami`).
2. **Decouple the Image Builder pipeline from `use_nat_instance`.** Today
   `nat_ami.tf` gates the pipeline/recipe/component/IAM/SG on `use_nat_instance`,
   so in gateway mode they vanish and you cannot build the AMI. Gate the build on
   a new **`build_nat_ami` flag (default `true`)**, independent of the egress
   mode; pure-gateway environments set it `false`. The `data.aws_ami.custom_nat`
   lookup is gated on `use_nat_instance` (read only when running instances), and
   its hard-error-on-no-match becomes the guard that stops you flipping to
   instances before an AMI exists.
3. **Retire AL2.** Remove the AL2 `user_data` local, the
   `data.aws_ami.amazon_linux_2` source, and the `use_custom_nat_ami` toggle
   (instance mode now *always* uses the custom AL2023 AMI). Drop the
   `use_custom_nat_ami` line from `infra.yml`.
4. **Verify the gateway wiring still holds** after the refactor: `aws_route.private`
   toggles its target on `use_nat_instance`, and `aws_nat_gateway` reuses the
   EIPs (both already true in the module today).

## Proposed decisions (open to change on review)

- **(a) Retire AL2 and drop `use_custom_nat_ami`: yes.** Instance mode is always
  the custom AL2023 AMI; the bootstrap-order guard moves to the
  `data.aws_ami.custom_nat` hard-error. One fewer flag.
- **(b) Pipeline gating: a dedicated `build_nat_ami` flag (default `true`)**,
  independent of `use_nat_instance`, so a gateway-only env can opt out.

## Migration safety (applying this to existing stage + prod)

Stage and prod already run AL2023 instances (`use_nat_instance = true`,
`use_custom_nat_ami = true`). Applying this refactor there **must be a no-op for
the running NAT instances** - no replacement. The AMI selected stays
`data.aws_ami.custom_nat` and the instance `user_data` stays `null`, so nothing
that forces replacement should change. Before applying:

- Set `TF_VAR_USE_NAT_INSTANCE = true` explicitly in the stage and prod
  environments first, so the newly-wired variable matches current behavior.
- Confirm the plan shows **no `aws_instance.nat` replacement** (only the removal
  of the now-unused `aws_ami.amazon_linux_2` data source and the
  `use_custom_nat_ami` variable). If a NAT replacement appears, stop - the AMI
  selection diverged.

The new gateway bootstrap only affects **new** environments; existing instance
environments are unaffected.

## Docs follow-up (on implementation)

Rewrite [docs/nat.md](../nat.md) to document both modes as first-class, with
clear run-in-either-mode instructions and the gateway-based bootstrap, and strip
the AL2 references. This plan can then be left as the historical record.

## Rollout

Implement on a branch; apply to **stage first** (verifying the no-op for the
running instances), then **prod**. Optionally validate the brand-new
gateway-bootstrap path end-to-end in `development` before relying on it for a
real new environment.

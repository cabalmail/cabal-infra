# NAT Gateway: evaluation and (deferred) migration plan

**Status: Deferred.** Cabalmail stays on AL2023 custom-AMI NAT instances. A
managed NAT Gateway is the architecturally cleaner option, but at the current
scale (four users, all family) it would cost roughly half the system's monthly
run-rate, which is not justified. Revisit if Cabalmail is ever run commercially
or at greater scale, if NAT-instance maintenance becomes a recurring burden, or
if AWS pricing changes materially. This document records the decision and the
exact steps to flip to a gateway when the time comes.

## Background

The 0.10.x NAT work was driven by Amazon Linux 2 reaching end of life. The
adopted solution was a **custom AL2023 NAT AMI** built by EC2 Image Builder
(`terraform/infra/modules/vpc/nat_ami.tf`, `nat-nftables-component.yaml`),
selected via `use_custom_nat_ami` and shipped to stage and prod. That resolved
the EOL driver while keeping the cheap NAT-instance model.

A NAT Gateway was evaluated as an alternative and deferred for cost.

## Why a NAT Gateway is attractive

It eliminates the entire class of brittleness this version fought through:

- No AMI, no firewall tool, no OS to keep off EOL, no boot-time config to get
  wrong. The 0.10.1 egress outage (a NAT instance that booted without a working
  masquerade rule, taking down all private-subnet egress) simply cannot happen
  with a managed gateway.
- Retiring it would remove the Image Builder pipeline, the custom AMI, the
  `use_custom_nat_ami` toggle, the two-phase bootstrap, and the AL2 `user_data`
  bootstrap entirely.
- **The module already supports it.** `terraform/infra/modules/vpc/route.tf`
  toggles the private default route between the NAT-instance ENI and the gateway
  on `use_nat_instance`, and `aws_nat_gateway` reuses the existing
  `aws_eip.nat_eip` addresses - so the stable outbound IPs
  (`smtp.<control-domain>`, SPF, the port-25 allow-list) are preserved with no
  re-issuing.

## Why it is deferred (cost)

Approximate us-east-1 monthly cost:

| Option | Fixed | Per-GB |
|---|---|---|
| 2x t3.micro NAT instances (current, one per AZ) | ~$15 | none |
| 1 NAT Gateway (single-AZ) | ~$33 | ~$0.045/GB |
| 2 NAT Gateways (per-AZ HA) | ~$65 | ~$0.045/GB |

At four-user scale the per-GB charge is negligible, but the fixed hourly cost of
even a single gateway is a large fraction of total run-rate. The NAT-instance
model is several times cheaper and, now that it runs a maintained AL2023 image,
adequately reliable for this scale. At commercial scale or higher volume, the
managed reliability would outweigh the cost and the gateway becomes the clear
choice.

## How to flip to a NAT Gateway when revisited

1. **Make `use_nat_instance` a wired-through variable.** It is currently
   hardcoded `true` in the `vpc` module block of `terraform/infra/main.tf`. Turn
   it into a root + module variable and echo it into `terraform.tfvars` in both
   the plan and apply blocks of `.github/workflows/infra.yml` (same pattern as
   `use_custom_nat_ami` / `quiesced`). NOTE: the workflow builds tfvars by
   echoing each `vars.TF_VAR_*`; a Terraform variable that is not echoed there
   is silently ignored (this bit us with `use_custom_nat_ami`).
2. **Decide single vs. dual gateway.** `aws_nat_gateway.nat` currently uses
   `count = length(var.az_list)` (one per AZ). For the cheaper single-AZ option,
   adjust the gateway `count` and the `aws_route.private` target so all private
   subnets route to the one gateway; accept that an AZ failure then takes egress
   down (the mail tiers already run a single task each, so this matches current
   app-layer redundancy).
3. **Set `use_nat_instance = false` and apply, in a window.** Terraform creates
   the gateway(s) on the existing EIPs, repoints the private routes, and destroys
   the NAT instances plus the (gated) Image Builder pipeline and recipe. The
   egress path is replaced, so expect a brief blip - same as any NAT change.
4. **Verify egress:** the mail tiers resume shipping logs within minutes (no VPC
   endpoints, so log flow is the canary), a test send completes in ~2-3 s and
   delivers, NLB target groups stay healthy.
5. **Retire or keep the instance path.** Either delete `nat_ami.tf`,
   `nat-nftables-component.yaml`, the `use_custom_nat_ami` variable and its
   `infra.yml` line, and the AL2 `user_data` local (then deregister the custom
   AMIs and remove the Image Builder pipeline) for a clean gateway-only module;
   or keep them dormant behind `use_nat_instance` as a documented cost-saving
   fallback.

See [docs/nat.md](../nat.md) for how NAT is wired today and the egress-outage
troubleshooting runbook.

/**
* Per-tier configuration used by for_each resources (SQS, security groups,
* log groups). Task definitions and services remain explicit because the
* tier-specific differences (EFS mounts, secrets, deployment constraints)
* make a for_each approach less readable.
*/

locals {
  tiers = {
    imap = {
      public_ports  = [143, 993]
      private_ports = [25]
    }
    smtp-in = {
      public_ports  = [25]
      private_ports = []
    }
    smtp-out = {
      public_ports  = [465, 587]
      private_ports = []
    }
  }

  # Phase 4 of docs/0.9.0/build-deploy-simplification-plan.md.
  # When /cabal/deployed_image_tag is the bootstrap sentinel, the ECR
  # repos are still empty (infra.yml is responsible for the very first
  # apply, before app.yml has ever pushed an image), so the task defs
  # point at a public-ECR placeholder so the cluster comes up cleanly.
  # The phase 1 lifecycle clause keeps subsequent app.yml deploys from
  # being clobbered.
  placeholder_image_tag = "bootstrap-placeholder"
  placeholder_image     = "public.ecr.aws/nginx/nginx:stable"

  tier_image = {
    for tier, _ in local.tiers :
    tier => var.image_tag == local.placeholder_image_tag ? local.placeholder_image : "${var.ecr_repository_urls[tier]}:${var.image_tag}"
  }

  # Target groups are keyed by function, not tier, because smtp-out
  # maps to two target groups (submission + starttls).
  target_groups = {
    imap       = { port = 143 }
    relay      = { port = 25 }
    submission = { port = 465 } # Dovecot submission (implicit TLS); NLB passes through to container port 465
    starttls   = { port = 587 }
  }

  # Flatten per-tier port lists into a map keyed by "tier-port" for
  # use with for_each on security group ingress rules.
  public_ingress = merge([
    for tier, cfg in local.tiers : {
      for port in cfg.public_ports : "${tier}-${port}" => {
        tier = tier
        port = port
      }
    }
  ]...)

  private_ingress = merge([
    for tier, cfg in local.tiers : {
      for port in cfg.private_ports : "${tier}-${port}" => {
        tier = tier
        port = port
      }
    }
  ]...)
}

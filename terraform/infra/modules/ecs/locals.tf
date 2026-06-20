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

  # Phase 4 of docs/0.9.x/build-deploy-simplification-plan.md.
  # When a tier's deployed-image-tag SSM parameter resolves to the
  # bootstrap sentinel, the ECR repos are still empty (infra.yml is
  # responsible for the very first apply, before app.yml has ever
  # pushed an image), so that tier's task def points at a public-ECR
  # placeholder so the cluster comes up cleanly. The phase 1 lifecycle
  # clause keeps subsequent app.yml deploys from being clobbered.
  # Tags arrive per tier (var.image_tags, one SSM key per tier - see
  # docs/0.10.x/per-tier-docker-deploy-plan.md) because app.yml only
  # rebuilds the tiers whose inputs changed, so sibling tiers
  # legitimately run different tags.
  placeholder_image_tag = "bootstrap-placeholder"
  placeholder_image     = "public.ecr.aws/nginx/nginx:stable"

  tier_image = merge(
    {
      for tier, _ in local.tiers :
      tier => var.image_tags[tier] == local.placeholder_image_tag ? local.placeholder_image : "${var.ecr_repository_urls[tier]}:${var.image_tags[tier]}"
    },
    # Sinkhole is not in local.tiers (different ingress/egress posture,
    # no SQS/SNS reconfigure path, no NLB), but it still resolves the
    # same way: placeholder during bootstrap, ECR-pinned tag thereafter.
    var.sinkhole ? {
      sinkhole = var.image_tags["sinkhole"] == local.placeholder_image_tag ? local.placeholder_image : "${var.ecr_repository_urls["sinkhole"]}:${var.image_tags["sinkhole"]}"
    } : {},
  )

  # Target groups are keyed by function, not tier, because smtp-out
  # maps to two target groups (submission + starttls).
  #
  # health_check_interval: imap probes every 10s so a freshly started
  # task is in service ~20s after Dovecot listens (healthy_threshold=2)
  # instead of 60s. The imap service deploys with a zero-task window
  # (single-task hard cap), so health-check latency is pure client-facing
  # downtime there. Trade-off accepted on imap: a broken task is removed
  # after unhealthy_threshold x 10s instead of x 30s, shrinking the
  # operator-debugging window by 3x. The smtp tiers roll with overlap
  # (min_healthy=100), so they keep the relaxed 30s probe. Phase 1 of
  # docs/0.10.x/imap-deploy-downtime-plan.md.
  target_groups = {
    imap       = { port = 143, health_check_interval = 10 }
    relay      = { port = 25, health_check_interval = 30 }
    submission = { port = 465, health_check_interval = 30 } # Dovecot submission (implicit TLS); NLB passes through to container port 465
    starttls   = { port = 587, health_check_interval = 30 }
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

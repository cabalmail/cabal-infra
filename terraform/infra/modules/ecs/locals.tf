/**
* Per-tier configuration used by for_each resources (SQS, security groups,
* log groups). Task definitions and services remain explicit because the
* tier-specific differences (EFS mounts, secrets, deployment constraints)
* make a for_each approach less readable.
*/

locals {
  tiers = {
    imap = {
      # No public ports: mailbox access is Cabalmail-client-only, so the
      # NLB carries no IMAP listener. 143 is VPC-only - it serves the NLB
      # target group's health checks, the API Lambdas' direct Cloud Map
      # dials (STARTTLS), and nothing else. Dovecot also listens on 993
      # in-container (task-def port mapping), but no SG rule admits it.
      public_ports  = []
      private_ports = [25, 143]
    }
    smtp-in = {
      public_ports  = [25]
      private_ports = []
    }
    smtp-out = {
      # No public ports: outbound submission is Cabalmail-client-only
      # (the send Lambda dials smtp-out.cabal.internal:465 directly), so
      # the NLB carries no 465/587 listeners. Both ports stay open
      # VPC-only for the target groups' health checks and the Lambda's
      # direct dials.
      public_ports  = []
      private_ports = [465, 587]
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
  # health_check_interval: only the relay group is attached to a listener
  # and actually probed by the NLB. The imap/submission/starttls groups
  # have no listener since the public IMAP/submission removal, so the NLB
  # never probes them and their interval values are inert (kept against a
  # future listener). Probe cadence for those tiers - and the deploy/
  # replacement latency it drives (phase 1 of
  # docs/0.10.x/imap-deploy-downtime-plan.md) - now lives in the
  # container-level healthCheck in their task definitions.
  # preserve_client_ip: NLB client IP preservation is disabled by default
  # for ip-type TCP targets, which hands sendmail the NLB ENI's private
  # address as the SMTP peer. On the relay TG that broke inbound SPF
  # evaluation (phase 1 of docs/0.10.x/inbound-auth-verification-plan.md:
  # opendmarc checked the sender's SPF record against the NLB's own IP
  # and failed every external message), and it also keyed sendmail's
  # confCONNECTION_RATE_THROTTLE and access_db to a single "client".
  # smtp-in's SG already allows 25 from 0.0.0.0/0, so no SG change rides
  # along. The imap TG stays at the default: with no IMAP listener on the
  # NLB it carries no traffic at all, so there is no client IP worth
  # preserving.
  # submission/starttls are left at the default too: smtp-out's Dovecot
  # auth posture is tuned for NLB-fronted peers, and nothing there needs
  # the real IP today.
  target_groups = {
    imap       = { port = 143, health_check_interval = 10, preserve_client_ip = null }
    relay      = { port = 25, health_check_interval = 30, preserve_client_ip = "true" }
    submission = { port = 465, health_check_interval = 30, preserve_client_ip = null } # Dovecot submission (implicit TLS); NLB passes through to container port 465
    starttls   = { port = 587, health_check_interval = 30, preserve_client_ip = null }
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

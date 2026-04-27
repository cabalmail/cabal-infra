# ── Cloud Map service discovery for Phase 3 metrics services ───
#
# Prometheus needs to find scrape targets across the cluster. Static IPs
# don't survive task replacement, and ECS doesn't auto-publish anything.
# Cloud Map is the standard pattern (the mail tiers already use it via
# `aws_service_discovery_private_dns_namespace.mail` in the ecs module).
#
# We use a separate namespace from the mail tiers — `cabal-monitoring`
# — so monitoring DNS records live alongside but never collide with
# mail-tier DNS. Each service registers an A record per task; Prometheus
# resolves the name with `dns_sd_configs` and scrapes every IP it gets
# back.

resource "aws_service_discovery_private_dns_namespace" "monitoring" {
  name        = "cabal-monitoring.cabal.internal"
  description = "Service discovery for the Phase 3 monitoring stack."
  vpc         = var.vpc_id
}

locals {
  monitoring_services = {
    prometheus          = { description = "Prometheus TSDB scraper." }
    alertmanager        = { description = "Alertmanager — receives alerts from Prometheus." }
    grafana             = { description = "Grafana — Prometheus dashboards." }
    cloudwatch-exporter = { description = "CloudWatch exporter — translates AWS metrics for Prometheus." }
    blackbox-exporter   = { description = "Blackbox exporter — synthetic HTTP/TCP probes." }
    node-exporter       = { description = "Node exporter — host CPU/memory/disk per cluster instance (DaemonSet)." }
  }
}

resource "aws_service_discovery_service" "monitoring" {
  for_each = local.monitoring_services

  name        = each.key
  description = each.value.description

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.monitoring.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  # ECS-managed custom health check; AWS deprecated the
  # `failure_threshold` argument and pins it at 1.
  health_check_custom_config {}
}

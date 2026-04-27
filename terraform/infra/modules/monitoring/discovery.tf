# ── Cloud Map service discovery for Phase 3 metrics services ───
#
# Prometheus needs to find scrape targets across the cluster. Static IPs
# don't survive task replacement, and ECS doesn't auto-publish anything.
# Cloud Map is the standard pattern (the mail tiers already use it via
# `aws_service_discovery_private_dns_namespace.mail` in the ecs module).
#
# We use a separate namespace from the mail tiers — `cabal-monitoring`
# — so monitoring DNS records live alongside but never collide with
# mail-tier DNS.
#
# The awsvpc-mode services register A records: Prometheus resolves the
# name with a `dns_sd_configs` type-A query and scrapes every IP it
# gets back at the configured port. node_exporter is the exception —
# it runs as a DAEMON with `network_mode = host`, and ECS rejects
# A-record service registrations in that mode (the host could have
# multiple tasks on different ports, so the port-from-A-record
# inference doesn't work). It registers SRV records instead, and
# Prometheus scrapes it via a `type: SRV` query.

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

  # AWS deprecated `failure_threshold` and pins it at 1 server-side, so
  # the value below is documentation more than control. We set it
  # explicitly because omitting the field causes Terraform to read drift
  # on every plan (server returns 1, code says nothing → diff →
  # forced-replace) and the replace fails because the ECS service has
  # live instances registered. ignore_changes is the belt-and-braces:
  # if a future provider version changes how it represents this block,
  # we still won't churn.
  health_check_custom_config {
    failure_threshold = 1
  }

  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

# node_exporter daemon — SRV record because ECS won't accept A-record
# registrations from host/bridge network-mode services (see comment at
# top of this file). Cloud Map auto-creates a paired A record for the
# SRV target, but Prometheus uses the SRV query so it picks up the
# host port directly without us hard-coding 9100 in prometheus.yml.
resource "aws_service_discovery_service" "node_exporter" {
  name        = "node-exporter"
  description = "Node exporter — host CPU/memory/disk per cluster instance (DaemonSet)."

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.monitoring.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "SRV"
    }
  }

  # See note on the for_each resource above re: failure_threshold +
  # ignore_changes — same drift trap, same defensive fix.
  health_check_custom_config {
    failure_threshold = 1
  }

  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

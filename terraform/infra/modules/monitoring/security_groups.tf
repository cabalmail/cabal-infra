# -- Security groups for the monitoring ALB, Kuma task, ntfy task -

resource "aws_security_group" "alb" {
  name        = "cabal-uptime-alb"
  description = "Public ALB for Uptime Kuma (Cognito-authenticated) and ntfy (token-authenticated)."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "alb_https_in" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-ingress-sgr
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet. Kuma path enforces Cognito; ntfy path enforces token auth in-app."
}

resource "aws_security_group_rule" "alb_https_out" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.alb.id
  description       = "Outbound HTTPS for ALB authenticate-cognito token exchange against the Cognito hosted UI domain."
}

resource "aws_security_group_rule" "alb_to_kuma" {
  type                     = "egress"
  from_port                = 3001
  to_port                  = 3001
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.kuma.id
  security_group_id        = aws_security_group.alb.id
  description              = "ALB forwards to Kuma task on 3001."
}

resource "aws_security_group_rule" "alb_to_ntfy" {
  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ntfy.id
  security_group_id        = aws_security_group.alb.id
  description              = "ALB forwards to ntfy task on 80."
}

resource "aws_security_group_rule" "alb_to_healthchecks" {
  type                     = "egress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.healthchecks.id
  security_group_id        = aws_security_group.alb.id
  description              = "ALB forwards to Healthchecks task on 8000."
}

resource "aws_security_group" "kuma" {
  name        = "cabal-uptime-kuma"
  description = "Uptime Kuma ECS task."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "kuma_from_alb" {
  type                     = "ingress"
  from_port                = 3001
  to_port                  = 3001
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.kuma.id
  description              = "Kuma accepts traffic from the uptime ALB."
}

resource "aws_security_group_rule" "kuma_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.kuma.id
  description       = "Outbound for probes (TCP/HTTP), DNS, ECR, CloudWatch, Lambda URL."
}

resource "aws_security_group" "ntfy" {
  name        = "cabal-ntfy"
  description = "Self-hosted ntfy ECS task."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "ntfy_from_alb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.ntfy.id
  description              = "ntfy accepts traffic from the uptime ALB."
}

resource "aws_security_group_rule" "ntfy_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.ntfy.id
  description       = "Outbound for DNS, ECR, CloudWatch, SSM (ECS Exec)."
}

resource "aws_security_group" "healthchecks" {
  name        = "cabal-healthchecks"
  description = "Self-hosted Healthchecks ECS task."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "healthchecks_from_alb" {
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.healthchecks.id
  description              = "Healthchecks accepts traffic from the uptime ALB."
}

resource "aws_security_group_rule" "healthchecks_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.healthchecks.id
  description       = "Outbound for DNS, ECR, CloudWatch, SSM (secrets, ECS Exec)."
}

# -- Phase 3: Grafana, Prometheus, Alertmanager, exporters ------

# Grafana ECS task - ALB ingress, broad egress (Prometheus
# data-source proxy, plugin downloads, ECR, CloudWatch, SSM).
resource "aws_security_group" "grafana" {
  name        = "cabal-grafana"
  description = "Grafana ECS task (Phase 3 metrics UI)."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "alb_to_grafana" {
  type                     = "egress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.grafana.id
  security_group_id        = aws_security_group.alb.id
  description              = "ALB forwards to Grafana task on 3000."
}

resource "aws_security_group_rule" "grafana_from_alb" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.grafana.id
  description              = "Grafana accepts traffic from the uptime ALB."
}

resource "aws_security_group_rule" "grafana_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.grafana.id
  description       = "Outbound for Prometheus proxy, ECR, CloudWatch, SSM."
}

# Prometheus ECS task - ingress only from Grafana (data-source proxy)
# and Alertmanager (alertmanager itself doesn't scrape Prometheus, but
# leaving the SG narrow is the right default). Egress is broad so
# Prometheus can scrape exporters via Cloud Map.
resource "aws_security_group" "prometheus" {
  name        = "cabal-prometheus"
  description = "Prometheus ECS task (Phase 3 TSDB)."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "prometheus_from_grafana" {
  type                     = "ingress"
  from_port                = 9090
  to_port                  = 9090
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.grafana.id
  security_group_id        = aws_security_group.prometheus.id
  description              = "Grafana proxies queries to Prometheus on 9090."
}

resource "aws_security_group_rule" "prometheus_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.prometheus.id
  description       = "Outbound for scraping exporters (Cloud Map A records resolve to private subnet IPs), Alertmanager push, ECR, CloudWatch."
}

# Alertmanager - ingress from Prometheus (push) and self (cluster mode
# - single replica today, but the port is allowed so adding a peer
# doesn't require an SG rule change later). Egress: HTTPS to the
# alert_sink Lambda Function URL, which is on the public Lambda URL
# domain.
resource "aws_security_group" "alertmanager" {
  name        = "cabal-alertmanager"
  description = "Alertmanager ECS task (Phase 3)."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "alertmanager_from_prometheus" {
  type                     = "ingress"
  from_port                = 9093
  to_port                  = 9093
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.prometheus.id
  security_group_id        = aws_security_group.alertmanager.id
  description              = "Prometheus pushes alerts to Alertmanager on 9093."
}

resource "aws_security_group_rule" "alertmanager_from_grafana" {
  type                     = "ingress"
  from_port                = 9093
  to_port                  = 9093
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.grafana.id
  security_group_id        = aws_security_group.alertmanager.id
  description              = "Grafana data-source proxy reaches Alertmanager for the alerts panel."
}

resource "aws_security_group_rule" "alertmanager_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.alertmanager.id
  description       = "Outbound HTTPS to the alert_sink Lambda Function URL."
}

# Single SG shared by cloudwatch_exporter and blackbox_exporter - both
# are stateless scrape-only services with the same ingress (Prometheus)
# and egress (CloudWatch / probes) shape.
resource "aws_security_group" "exporters" {
  name        = "cabal-monitoring-exporters"
  description = "Cluster-scope Prometheus exporters (cloudwatch, blackbox)."
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "exporters_from_prometheus" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9120
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.prometheus.id
  security_group_id        = aws_security_group.exporters.id
  description              = "Prometheus scrapes exporters in the 9100-9120 port range (cloudwatch=9106, blackbox=9115)."
}

resource "aws_security_group_rule" "exporters_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  security_group_id = aws_security_group.exporters.id
  description       = "Outbound for CloudWatch API (cloudwatch_exporter) and HTTP/TCP probes (blackbox_exporter)."
}

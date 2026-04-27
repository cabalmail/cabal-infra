# ── Public ALB fronting Kuma (Cognito-auth) and ntfy (no auth) ─
#
# Default listener action forwards to Kuma with Cognito authenticate-oidc.
# A host-header listener rule peels off requests to ntfy.<control-domain>
# and forwards them to ntfy without any ALB-level auth; ntfy enforces its
# own bearer-token auth.

#tfsec:ignore:aws-elb-alb-not-public
resource "aws_lb" "uptime" {
  name               = "cabal-uptime-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.uptime.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.cert_arn

  default_action {
    type  = "authenticate-cognito"
    order = 1

    authenticate_cognito {
      user_pool_arn              = var.user_pool_arn
      user_pool_client_id        = aws_cognito_user_pool_client.kuma.id
      user_pool_domain           = var.user_pool_domain
      scope                      = "openid email profile"
      on_unauthenticated_request = "authenticate"
      session_timeout            = 43200
    }
  }

  default_action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.kuma.arn
  }
}

#tfsec:ignore:aws-elb-http-not-used
resource "aws_lb_listener_rule" "ntfy" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ntfy.arn
  }

  condition {
    host_header {
      values = ["ntfy.${var.control_domain}"]
    }
  }
}

# Healthchecks UI sits behind the same Cognito challenge as Kuma. Per-host
# rule (not the default action) so we can give it its own Cognito client
# with its own callback URL.
#tfsec:ignore:aws-elb-http-not-used
resource "aws_lb_listener_rule" "healthchecks" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 110

  action {
    type  = "authenticate-cognito"
    order = 1

    authenticate_cognito {
      user_pool_arn              = var.user_pool_arn
      user_pool_client_id        = aws_cognito_user_pool_client.healthchecks.id
      user_pool_domain           = var.user_pool_domain
      scope                      = "openid email profile"
      on_unauthenticated_request = "authenticate"
      session_timeout            = 43200
    }
  }

  action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.healthchecks.arn
  }

  condition {
    host_header {
      values = ["heartbeat.${var.control_domain}"]
    }
  }
}

# Grafana (Phase 3) — same Cognito-auth pattern as Healthchecks. Local
# Grafana admin password is still required for admin actions.
#tfsec:ignore:aws-elb-http-not-used
resource "aws_lb_listener_rule" "grafana" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 120

  action {
    type  = "authenticate-cognito"
    order = 1

    authenticate_cognito {
      user_pool_arn              = var.user_pool_arn
      user_pool_client_id        = aws_cognito_user_pool_client.grafana.id
      user_pool_domain           = var.user_pool_domain
      scope                      = "openid email profile"
      on_unauthenticated_request = "authenticate"
      session_timeout            = 43200
    }
  }

  action {
    type             = "forward"
    order            = 2
    target_group_arn = aws_lb_target_group.grafana.arn
  }

  condition {
    host_header {
      values = ["metrics.${var.control_domain}"]
    }
  }
}

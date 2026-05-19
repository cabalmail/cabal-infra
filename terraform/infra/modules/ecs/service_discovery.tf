/**
* Cloud Map service discovery for inter-tier communication.
*
* The IMAP container accepts mail for local delivery on port 25.  SMTP-IN
* and SMTP-OUT need to reach it by hostname (via the sendmail mailertable).
* The public NLB cannot be used because its port 25 listener routes to the
* relay (SMTP-IN) target group, not IMAP - creating a loop.
*
* Cloud Map registers the IMAP task's ENI IP directly in a private DNS
* namespace so that smtp-in and smtp-out can connect to it without going
* through the NLB.
*/

resource "aws_service_discovery_private_dns_namespace" "mail" {
  name        = "cabal.internal"
  description = "Internal service discovery for ECS mail tiers"
  vpc         = var.vpc_id
}

resource "aws_service_discovery_service" "imap" {
  name = "imap"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.mail.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  # AWS pins HealthCheckCustomConfig.FailureThreshold to 1 server-side
  # even when the block is absent from the Terraform config; Terraform
  # otherwise reads the server-side value as drift and schedules a
  # forced replacement. The replacement fails because the ECS task is
  # registered as an instance out-of-band (DeleteService rejects active
  # instances), and even when a replacement does land, the running task
  # remains bound to the destroyed predecessor's registry ARN - ECS
  # only registers tasks with Cloud Map at task START. That orphan was
  # the proximate cause of the 2026-05-18 inbound-mail outage. The
  # original monitoring module shipped with this same lifecycle for
  # exactly the same reason; it was removed in 0.9.21 to clear a
  # deprecation warning. terraform_data.imap_cloud_map_lifecycle below
  # handles the residual case where a recreation is unavoidable.
  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

# Brackets the Cloud Map service's lifecycle. Even with ignore_changes
# above, a future ForceNew (different deprecated field, provider
# behavior change, manual import) can still require replacement; this
# resource makes that path safe.
#
# triggers_replace tracks aws_service_discovery_service.imap.id, so a
# recreation of the Cloud Map service triggers replacement here too.
# var.quiesced is included so resume/quiesce transitions restore the
# correct desired_count.
#
# Default Terraform ordering does the right thing:
#   destroy on replace:
#     terraform_data.destroy (drains ECS to 0, waits services-stable)
#     -> aws_service_discovery_service.destroy (now succeeds; no
#        registered instances)
#   create on replace:
#     aws_service_discovery_service.create (new ARN)
#     -> aws_ecs_service.update (service_registries.registry_arn ->
#        new ARN)
#     -> terraform_data.create (force-new-deployment so a fresh task
#        registers with the new Cloud Map service)
#
# The depends_on = [aws_ecs_service.imap] is what guarantees the
# create-provisioner runs AFTER aws_ecs_service has been updated to
# point at the new Cloud Map ARN; without it, the force-new-deployment
# could fire while the ECS service still has the destroyed ARN in
# service_registries and the new task would fail to register.
resource "terraform_data" "imap_cloud_map_lifecycle" {
  triggers_replace = [
    aws_service_discovery_service.imap.id,
    var.quiesced,
  ]

  input = {
    cluster_name     = aws_ecs_cluster.mail.name
    ecs_service_name = aws_ecs_service.imap.name
    region           = var.region
    desired_count    = var.quiesced ? 0 : 1
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -eu
      echo "[imap-cm-lifecycle] draining ${self.input.ecs_service_name} before Cloud Map service is destroyed"
      aws --region ${self.input.region} ecs update-service \
        --cluster ${self.input.cluster_name} \
        --service ${self.input.ecs_service_name} \
        --desired-count 0 \
        --no-cli-pager >/dev/null
      aws --region ${self.input.region} ecs wait services-stable \
        --cluster ${self.input.cluster_name} \
        --services ${self.input.ecs_service_name}
    EOT
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      echo "[imap-cm-lifecycle] restoring ${self.input.ecs_service_name} (desired=${self.input.desired_count}) and forcing redeploy"
      aws --region ${self.input.region} ecs update-service \
        --cluster ${self.input.cluster_name} \
        --service ${self.input.ecs_service_name} \
        --desired-count ${self.input.desired_count} \
        --force-new-deployment \
        --no-cli-pager >/dev/null
    EOT
  }

  depends_on = [aws_ecs_service.imap]
}

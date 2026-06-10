#!/usr/bin/env bash
#
# Out-of-band ECS application deploy. Clones the running task definition
# of cabal-${TIER} on cluster cabal-mail, rewrites every container image
# whose repo basename is cabal-${TIER} to point at the freshly-pushed
# tag, registers a new task-def revision, and rolls the service to it.
#
# For the imap tier (single-task service, zero-task deploy window) two
# extra stages run between registration and the roll - phase 5 of
# docs/0.10.x/imap-deploy-downtime-plan.md:
#   1. Pre-flight: the new revision runs as a one-shot task with
#      PREFLIGHT=1 (entrypoint validation only, exits without starting
#      services). A failing preflight aborts the deploy while the old
#      task is still serving. PREFLIGHT_DISABLE=1 skips it.
#   2. The planned-maintenance flag is raised (maintenance-flag.sh set)
#      immediately before update-service, so the IMAP-backed Lambdas
#      503 gracefully during the roll. The new container clears it once
#      Dovecot serves.
#
# Phase 3 of docs/0.9.x/build-deploy-simplification-plan.md introduces
# this path: app.yml mutates ECS directly via the AWS CLI instead of
# routing through Terraform. The phase 1 lifecycle clause
# (ignore_changes = [container_definitions]) protects the new revision
# from being clobbered by a topology-only Terraform apply, and the
# phase 1 .github/scripts/refresh-ssm-from-running.sh keeps SSM
# /cabal/deployed_image_tag in lockstep with whatever app.yml just
# deployed so a Terraform-driven topology change re-pins to reality
# rather than to a stale SSM value.
#
# After update-service this script waits for the service to reach a
# stable rollout (aws ecs wait services-stable). That is what makes
# app.yml's completion a meaningful "this tier is actually deployed and
# healthy" barrier: infra.yml's plan job orders itself behind the
# sibling app.yml run for the same push (.github/scripts/wait-for-app-
# deploy.sh) so that refresh-ssm-from-running.sh reads the post-roll tag
# rather than the pre-roll (stale) one. Without the wait, this script
# returned as soon as update-service was accepted - before the new task
# was running - so "app.yml finished" did not imply "the image is
# deployed", and a marker-triggered Terraform task-def re-registration
# could still be paired with a not-yet-rolled image. See CHANGELOG
# 0.10.9 (the incident) and 0.10.12 (this fix).
#
# Usage:
#   deploy-ecs-service.sh <tier> <image_tag> [cluster] [service_override]
#
# Args:
#   tier              e.g. imap, smtp-in, prometheus. Maps to ECS
#                     service cabal-<tier> and ECR repo cabal-<tier>.
#   image_tag         e.g. sha-abc12345. Must already exist in ECR.
#   cluster           Optional; defaults to cabal-mail.
#   service_override  Optional; defaults to cabal-<tier>. Use this when
#                     a second ECS service consumes the same image
#                     under a different service name (e.g. the
#                     us-east-1-pinned cloudwatch-exporter task uses
#                     the cabal-cloudwatch-exporter image but runs as
#                     cabal-cloudwatch-exporter-us-east-1).
#
# Exit codes:
#   0  rolled the service and it reached a stable rollout on the new
#      revision
#   1  required arg missing, service not found, no container in the task
#      def references cabal-<tier>:<anything>, the imap preflight task
#      ran and did not exit 0, the rolled service did not stabilize
#      within the wait window, or it stabilized on a different revision
#      than the one we registered (the imap service runs a deployment
#      circuit breaker with rollback - phase 2 of
#      docs/0.10.x/imap-deploy-downtime-plan.md - so a broken image
#      stabilizes back on the previous revision; the smtp services have
#      no breaker, so a broken image never stabilizes and the wait times
#      out)
#   non-0 from aws CLI on any other failure

set -euo pipefail

TIER="${1:?tier required}"
TAG="${2:?image_tag required}"
CLUSTER="${3:-cabal-mail}"
SERVICE="${4:-cabal-${TIER}}"
REPO_BASENAME="cabal-${TIER}"

log() { echo "[deploy-ecs-service] $*"; }

td_arn="$(aws ecs describe-services \
  --cluster "${CLUSTER}" \
  --services "${SERVICE}" \
  --query 'services[0].taskDefinition' \
  --output text 2>/dev/null || echo "None")"

if [ -z "${td_arn}" ] || [ "${td_arn}" = "None" ]; then
  log "service ${SERVICE} not found on ${CLUSTER}; cannot deploy ${TIER}"
  exit 1
fi

log "current task def for ${SERVICE}: ${td_arn}"

td_json="$(aws ecs describe-task-definition \
  --task-definition "${td_arn}" \
  --query 'taskDefinition' \
  --output json)"

# Rewrite every container image whose repo basename matches REPO_BASENAME.
# The repo basename is the path component after the last '/' in the
# image reference. For ECR images that is the repository name itself;
# for non-ECR placeholder images (e.g. public.ecr.aws/nginx/nginx) it
# will be 'nginx', which does not match cabal-<tier>, so those are left
# alone. Read-only fields are stripped so the result is a valid input
# to register-task-definition.
new_td_json="$(echo "${td_json}" | jq \
  --arg basename "${REPO_BASENAME}" \
  --arg tag "${TAG}" '
  def repo_base(img):
    img | split(":")[0] | split("@")[0] | split("/") | .[-1];
  .containerDefinitions = (
    .containerDefinitions | map(
      if repo_base(.image) == $basename
      then .image = ((.image | split(":")[0] | split("@")[0]) + ":" + $tag)
      else .
      end
    )
  )
  | del(
      .taskDefinitionArn,
      .revision,
      .status,
      .requiresAttributes,
      .compatibilities,
      .registeredAt,
      .registeredBy
    )
')"

matched_image="$(echo "${new_td_json}" | jq -r \
  --arg basename "${REPO_BASENAME}" '
  def repo_base(img):
    img | split(":")[0] | split("@")[0] | split("/") | .[-1];
  [.containerDefinitions[] | select(repo_base(.image) == $basename) | .image] | first // ""
')"

if [ -z "${matched_image}" ]; then
  log "no container in ${td_arn} has repo basename ${REPO_BASENAME}; refusing to deploy"
  exit 1
fi

log "rewrote container image to: ${matched_image}"

new_td_arn="$(aws ecs register-task-definition \
  --cli-input-json "${new_td_json}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)"
log "registered new task def: ${new_td_arn}"

# -- IMAP pre-flight: validate the new revision off the LB ------
# A bad image (broken entrypoint, missing secret, bad IAM) used to be
# discovered only after the old single-task IMAP container had already
# stopped, turning a build mistake into the full outage-plus-rollback
# window. Instead, run the new revision as a one-shot task with
# PREFLIGHT=1 overlaid - entrypoint.sh runs every preparation step
# (secrets, EFS, Cognito, DynamoDB, sendmail compile) and exits 0
# instead of starting services - while the old task is still serving.
# Only a clean exit lets the roll proceed. Costs ~30-60s on the success
# path (the image layers are already on the instance courtesy of
# prepull-image.sh). Phase 5 of docs/0.10.x/imap-deploy-downtime-plan.md.
#
# Failure semantics:
#   - task ran and did not exit 0: HARD FAIL, deploy aborts with the
#     old task untouched and the maintenance flag never raised.
#   - task could not be started (missing ecs:RunTask / iam:PassRole
#     grants in this account - the CI policies are hand-managed - or no
#     spare capacity): fail-soft, warn and deploy on the old
#     discover-failures-during-the-roll path.
# PREFLIGHT_DISABLE=1 skips it (operator escape hatch).
if [ "${TIER}" = "imap" ] && [ "${PREFLIGHT_DISABLE:-0}" != "1" ]; then
  net_config="$(aws ecs describe-services \
    --cluster "${CLUSTER}" \
    --services "${SERVICE}" \
    --query 'services[0].networkConfiguration' \
    --output json)"

  preflight_overrides="$(jq -cn --arg name "${TIER}" \
    '{containerOverrides: [{name: $name, environment: [{name: "PREFLIGHT", value: "1"}]}]}')"

  if run_out="$(aws ecs run-task \
    --cluster "${CLUSTER}" \
    --task-definition "${new_td_arn}" \
    --launch-type EC2 \
    --network-configuration "${net_config}" \
    --overrides "${preflight_overrides}" \
    --started-by deploy-preflight \
    --output json 2>/dev/null)"; then
    preflight_task_arn="$(echo "${run_out}" | jq -r '.tasks[0].taskArn // empty')"
    preflight_failures="$(echo "${run_out}" | jq -r '[.failures[]?.reason // "unknown"] | join(", ")')"
  else
    preflight_task_arn=""
    preflight_failures="run-task call failed (missing IAM grant?)"
  fi

  if [ -z "${preflight_task_arn}" ]; then
    log "WARN: could not start preflight task (${preflight_failures:-no reason given});"
    log "WARN: proceeding without preflight - failures will surface during the roll"
  else
    log "preflight task ${preflight_task_arn} started; waiting for it to stop"
    if ! aws ecs wait tasks-stopped --cluster "${CLUSTER}" --tasks "${preflight_task_arn}"; then
      log "ERROR: preflight task did not stop within the wait window; aborting deploy"
      aws ecs stop-task --cluster "${CLUSTER}" --task "${preflight_task_arn}" \
        --reason "preflight timeout" >/dev/null 2>&1 || true
      exit 1
    fi
    preflight_desc="$(aws ecs describe-tasks \
      --cluster "${CLUSTER}" \
      --tasks "${preflight_task_arn}" \
      --query 'tasks[0]' \
      --output json)"
    preflight_exit="$(echo "${preflight_desc}" | jq -r '.containers[0].exitCode // "none"')"
    if [ "${preflight_exit}" = "0" ]; then
      log "preflight passed; proceeding with the roll"
    else
      preflight_reason="$(echo "${preflight_desc}" | jq -r '.stoppedReason // "unknown"')"
      log "ERROR: preflight exited ${preflight_exit} (${preflight_reason});"
      log "ERROR: aborting deploy before any service mutation - old task still serving"
      exit 1
    fi
  fi
fi

# Raise the planned-maintenance flag immediately before triggering the
# roll: the single-task IMAP service has a true zero-task window, and
# the flag makes the IMAP-backed Lambdas return a friendly 503 instead
# of relaying a raw connection error. It lives here (not in app.yml) so
# it goes up only AFTER a passing preflight - the flag 503s clients the
# moment it is set, and raising it before the preflight would extend
# that artificial outage by a minute while the old task is still
# perfectly healthy. The new container clears it once Dovecot is
# serving (docker/shared/clear-maintenance.sh); the `until` TTL baked
# in by maintenance-flag.sh is the backstop if the roll dies.
if [ "${TIER}" = "imap" ]; then
  "$(cd "$(dirname "$0")" && pwd)/maintenance-flag.sh" set
fi

aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "${SERVICE}" \
  --task-definition "${new_td_arn}" >/dev/null
log "service ${SERVICE} rolling to ${new_td_arn}; waiting for stability"

# Block until the service is fully rolled (rolloutState COMPLETED,
# runningCount == desiredCount, no in-flight deployment). This is the
# barrier infra.yml's wait-for-app-deploy.sh orders behind. On the smtp
# services (no deployment circuit breaker) a broken image never
# stabilizes, so the wait times out and we exit non-zero rather than
# report a deploy that never actually came up. `if` keeps set -e from
# aborting before we can log the timeout.
if aws ecs wait services-stable --cluster "${CLUSTER}" --services "${SERVICE}"; then
  log "service ${SERVICE} reached a stable rollout"
else
  log "ERROR: ${SERVICE} did not stabilize on ${new_td_arn} within the wait window"
  exit 1
fi

# "Stable" is not "deployed": the imap service runs a deployment circuit
# breaker with rollback (phase 2 of docs/0.10.x/imap-deploy-downtime-plan.md),
# so a broken image stabilizes back on the PREVIOUS revision and the wait
# above succeeds. Assert the service actually landed on the revision we
# registered before reporting success.
stable_td_arn="$(aws ecs describe-services \
  --cluster "${CLUSTER}" \
  --services "${SERVICE}" \
  --query 'services[0].taskDefinition' \
  --output text)"

if [ "${stable_td_arn}" = "${new_td_arn}" ]; then
  log "service ${SERVICE} stable on ${new_td_arn}"
else
  log "ERROR: ${SERVICE} stabilized on ${stable_td_arn}, not ${new_td_arn};"
  log "ERROR: the deployment circuit breaker rolled the deploy back"
  exit 1
fi

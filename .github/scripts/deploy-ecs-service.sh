#!/usr/bin/env bash
#
# Out-of-band ECS application deploy. Clones the running task definition
# of cabal-${TIER} on cluster cabal-mail, rewrites every container image
# whose repo basename is cabal-${TIER} to point at the freshly-pushed
# tag, registers a new task-def revision, and rolls the service to it.
#
# Phase 3 of docs/0.9.0/build-deploy-simplification-plan.md introduces
# this path: app.yml mutates ECS directly via the AWS CLI instead of
# routing through Terraform. The phase 1 lifecycle clause
# (ignore_changes = [container_definitions]) protects the new revision
# from being clobbered by a topology-only Terraform apply, and the
# phase 1 .github/scripts/refresh-ssm-from-running.sh keeps SSM
# /cabal/deployed_image_tag in lockstep with whatever app.yml just
# deployed so a Terraform-driven topology change re-pins to reality
# rather than to a stale SSM value.
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
#   0  rolled the service successfully (or service already up to date)
#   1  required arg missing, service not found, or no container in the
#      task def references cabal-<tier>:<anything>
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

aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "${SERVICE}" \
  --task-definition "${new_td_arn}" >/dev/null
log "service ${SERVICE} rolling to ${new_td_arn}"

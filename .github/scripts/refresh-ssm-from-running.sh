#!/usr/bin/env bash
#
# Reconcile the per-tier image-tag SSM parameters
# (/cabal/deployed_image_tag/<tier>) with the image tags actually
# running on the cabal-* ECS services of the cabal-mail cluster, and
# keep the legacy global parameter (/cabal/deployed_image_tag) in
# lockstep with the imap tier for backward compatibility.
#
# Phase 1 of docs/0.9.x/build-deploy-simplification-plan.md adds
# lifecycle { ignore_changes = [container_definitions] } to the ECS
# task definitions so out-of-band app deploys (which mutate the image
# tag via aws ecs register-task-definition) are not rolled back by a
# topology-only Terraform apply. The ignore_changes clause does not by
# itself protect against the case where Terraform regenerates a task
# def on a legitimate topology change (a revision-marker bump): the
# fresh task def re-pins the image tag to whatever SSM holds, which may
# be stale relative to what is actually running.
#
# Phase 2 of docs/0.10.x/per-tier-docker-deploy-plan.md makes the SSM
# model per-tier: app.yml's docker job builds and rolls only the tiers
# whose inputs changed, so sibling tiers legitimately diverge in image
# tag, and one global key (historically read from the imap service)
# would silently corrupt the non-imap task defs on regeneration.
# Terraform reads one key per tier at plan time (terraform/infra/
# main.tf); this script runs at the start of the Terraform plan job and
# copies each tier's RUNNING tag into that tier's key, so a regenerated
# task def matches the reality of its own tier.
#
# Read only SETTLED tags. Before reading any image, wait for every
# matched service to reach a stable rollout (aws ecs wait
# services-stable: rolloutState COMPLETED, runningCount == desiredCount,
# no in-flight deployment). A mid-roll service's task def is the DESIRED
# revision, which may not yet be running or may be a roll that never
# completes; pinning SSM from it is how a stale tag slips in. The race
# this guards against (CHANGELOG 0.10.9): app.yml and infra.yml run
# concurrently for the same push, infra reads a tier before app.yml has
# rolled it, and a marker-triggered task-def re-registration pairs the
# new task def with the old image. infra.yml orders itself behind the
# sibling app.yml run (.github/scripts/wait-for-app-deploy.sh) so by the
# time we run, the changed tiers are already rolled to the new tag; this
# stability gate is the belt-and-suspenders backstop that refuses to
# capture a half-rolled tag even if the ordering step is bypassed.
#
# Failure modes:
#   - Cluster does not exist (first run): exit 0, log a notice.
#   - No cabal-* services on the cluster (first run): exit 0, log a
#     notice.
#   - A service does not reach a stable rollout within the wait window:
#     exit non-zero. Refusing to pin a possibly mid-roll tag is the
#     point; a genuinely stuck service is a real problem the plan
#     should surface rather than paper over with a stale pin.
#   - A service's task def has no container image in the cabal-<tier>
#     ECR repo: skip it, log a notice. Covers the bootstrap window
#     (task defs point at the public placeholder image) and secondary
#     services whose image belongs to another tier (e.g.
#     cabal-cloudwatch-exporter-us-east-1, which runs the
#     cabal-cloudwatch-exporter image and is reconciled via the
#     primary service).
#   - A per-tier SSM parameter does not exist yet: skip it, log a
#     notice. Terraform seeds every per-tier key (with the bootstrap
#     sentinel) on the next apply; the run after that reconciles it.
#     This script never creates a per-tier key - doing so would collide
#     with the Terraform resource that owns it.
#   - The legacy SSM parameter does not exist: skip it, log a notice.
#   - aws CLI fails for any other reason: exit non-zero.

set -euo pipefail

CLUSTER="${CLUSTER:-cabal-mail}"
SSM_PARAM="${SSM_PARAM:-/cabal/deployed_image_tag}"
LEGACY_TIER="${LEGACY_TIER:-imap}"

log() { echo "[refresh-ssm-from-running] $*"; }

# Compare-and-write one SSM parameter. Skips missing parameters (arg 3
# is the notice to log in that case) and short-circuits when the value
# already matches, so steady-state runs add no SSM version history.
update_param() {
  local param="$1" tag="$2" missing_notice="$3"
  local current
  current="$(aws ssm get-parameter \
    --name "${param}" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || echo "__MISSING__")"

  if [ "${current}" = "__MISSING__" ]; then
    log "SSM parameter ${param} does not exist; ${missing_notice}"
    return 0
  fi

  if [ "${current}" = "${tag}" ]; then
    log "SSM ${param}=${current} already matches; no update"
    return 0
  fi

  log "SSM ${param}=${current} but the running tag is ${tag}; updating"
  aws ssm put-parameter \
    --name "${param}" \
    --value "${tag}" \
    --type String \
    --overwrite >/dev/null
  log "SSM ${param} now = ${tag}"
}

cluster_status="$(aws ecs describe-clusters \
  --clusters "${CLUSTER}" \
  --query 'clusters[0].status' \
  --output text 2>/dev/null || echo "MISSING")"

if [ "${cluster_status}" != "ACTIVE" ]; then
  log "cluster ${CLUSTER} not ACTIVE (status=${cluster_status}); nothing to reconcile"
  exit 0
fi

# Every cabal-* service on the cluster is a tier whose key we maintain;
# the tier name is the service name minus the cabal- prefix. Anything
# else on the cluster is not ours to reconcile.
services=()
for arn in $(aws ecs list-services \
  --cluster "${CLUSTER}" \
  --query 'serviceArns[]' \
  --output text); do
  name="${arn##*/}"
  case "${name}" in
    cabal-*) services+=("${name}") ;;
    *) log "skipping non-cabal service ${name}" ;;
  esac
done

if [ "${#services[@]}" -eq 0 ]; then
  log "no cabal-* services on ${CLUSTER}; nothing to reconcile"
  exit 0
fi

# Wait for every matched service to settle before trusting any tag, so
# a mid-roll (or never-completing) deployment cannot leak a stale/unrun
# tag into SSM. In steady state this returns immediately. The waiter
# takes at most 10 services per call, so chunk. `if` keeps set -e from
# aborting before we can log the timeout.
log "waiting for ${#services[@]} service(s) to reach a stable rollout: ${services[*]}"
i=0
while [ "${i}" -lt "${#services[@]}" ]; do
  chunk=("${services[@]:i:10}")
  if ! aws ecs wait services-stable --cluster "${CLUSTER}" --services "${chunk[@]}"; then
    log "ERROR: a service in [${chunk[*]}] did not reach a stable rollout;"
    log "ERROR: refusing to pin possibly mid-roll image tags"
    exit 1
  fi
  i=$((i + 10))
done

legacy_tag=""
for service in "${services[@]}"; do
  tier="${service#cabal-}"

  # Read the task def only now that the rollout has settled - a value
  # read before the wait could have been a desired-but-not-running
  # revision.
  task_def_arn="$(aws ecs describe-services \
    --cluster "${CLUSTER}" \
    --services "${service}" \
    --query 'services[0].taskDefinition' \
    --output text)"

  if [ -z "${task_def_arn}" ] || [ "${task_def_arn}" = "None" ]; then
    log "service ${service} has no task definition; skipping"
    continue
  fi

  # The tier's image is the container whose ECR repo basename is
  # cabal-<tier>. Public placeholder images (bootstrap) and images
  # belonging to other tiers (the us-east-1 cloudwatch-exporter
  # service) do not match and are skipped.
  running_image="$(aws ecs describe-task-definition \
    --task-definition "${task_def_arn}" \
    --query 'taskDefinition.containerDefinitions' \
    --output json | jq -r --arg repo "cabal-${tier}" '
      def repo_base(img):
        img | split(":")[0] | split("@")[0] | split("/") | .[-1];
      [.[] | select(repo_base(.image) == $repo) | .image] | first // ""')"

  if [ -z "${running_image}" ]; then
    log "no container in ${task_def_arn} runs the cabal-${tier} image; skipping ${service}"
    continue
  fi

  # Image looks like ".../cabal-imap:sha-abc12345". Strip everything
  # before the last ':' to get the tag.
  running_tag="${running_image##*:}"

  if [ -z "${running_tag}" ] || [ "${running_tag}" = "${running_image}" ]; then
    log "image ${running_image} has no tag separator; skipping ${service}"
    continue
  fi

  if [ "${tier}" = "${LEGACY_TIER}" ]; then
    legacy_tag="${running_tag}"
  fi

  update_param "${SSM_PARAM}/${tier}" "${running_tag}" \
    "Terraform seeds it on the next apply; the run after that reconciles it"
done

# Keep the legacy global key tracking the imap tier, exactly as it did
# before the per-tier keys existed. It is the fallback Terraform reads
# for any tier whose per-tier key still holds the bootstrap sentinel
# (the cutover path), and remains the bootstrap sentinel carrier for
# brand-new environments.
if [ -n "${legacy_tag}" ]; then
  update_param "${SSM_PARAM}" "${legacy_tag}" "nothing to reconcile"
else
  log "service cabal-${LEGACY_TIER} not found or not readable; leaving legacy ${SSM_PARAM} untouched"
fi

#!/usr/bin/env bash
#
# Reconcile /cabal/deployed_image_tag with the image tag actually running
# on the canonical mail-tier ECS service (cabal-imap on the cabal-mail
# cluster). Phase 1 of docs/0.9.x/build-deploy-simplification-plan.md
# adds lifecycle { ignore_changes = [container_definitions] } to the ECS
# task definitions so out-of-band app deploys (which mutate the image
# tag via aws ecs register-task-definition) are not rolled back by a
# topology-only Terraform apply. The ignore_changes clause does not by
# itself protect against the case where Terraform regenerates a task
# def on a legitimate topology change: it would still re-pin the image
# tag to whatever /cabal/deployed_image_tag holds, which may be stale
# relative to what is actually running.
#
# This script runs at the start of the Terraform plan job and copies
# the running tag back into SSM, so the regenerated task def matches
# reality.
#
# Read only a SETTLED tag. Before reading the image, wait for the
# canonical service to reach a stable rollout (aws ecs wait
# services-stable: rolloutState COMPLETED, runningCount == desiredCount,
# no in-flight deployment). A mid-roll service's task def is the DESIRED
# revision, which may not yet be running or may be a roll that never
# completes; pinning SSM from it is how a stale tag slips in. The race
# this guards against (CHANGELOG 0.10.9): app.yml and infra.yml run
# concurrently for the same push, infra reads imap before app.yml has
# rolled it, and a marker-triggered task-def re-registration pairs the
# new task def with the old image. infra.yml orders itself behind the
# sibling app.yml run (.github/scripts/wait-for-app-deploy.sh) so by the
# time we run, imap is already rolled to the new tag; this stability
# gate is the belt-and-suspenders backstop that refuses to capture a
# half-rolled tag even if the ordering step is bypassed.
#
# Until phase 3 (out-of-band app deploys) lands, this script is a
# steady-state no-op: every deploy still flows through Terraform with
# SSM as the source of truth, and SSM and the running tag stay in
# lockstep. In steady state the service is already stable, so the wait
# returns immediately and the read/compare/write below is unchanged.
#
# Failure modes:
#   - Cluster does not exist (first run): exit 0, log a notice.
#   - Service does not exist (first run): exit 0, log a notice.
#   - Service has no task def yet (transient): exit 0, log a notice.
#   - Service does not reach a stable rollout within the wait window:
#     exit non-zero. Refusing to pin a possibly mid-roll tag is the
#     point; a genuinely stuck canonical service is a real problem the
#     plan should surface rather than paper over with a stale pin.
#   - SSM parameter does not exist: exit 0, log a notice. The plan
#     job will create it on first apply via Terraform.
#   - aws CLI fails for any other reason: exit non-zero.

set -euo pipefail

CLUSTER="${CLUSTER:-cabal-mail}"
CANONICAL_SERVICE="${CANONICAL_SERVICE:-cabal-imap}"
CANONICAL_CONTAINER="${CANONICAL_CONTAINER:-imap}"
SSM_PARAM="${SSM_PARAM:-/cabal/deployed_image_tag}"

log() { echo "[refresh-ssm-from-running] $*"; }

cluster_status="$(aws ecs describe-clusters \
  --clusters "${CLUSTER}" \
  --query 'clusters[0].status' \
  --output text 2>/dev/null || echo "MISSING")"

if [ "${cluster_status}" != "ACTIVE" ]; then
  log "cluster ${CLUSTER} not ACTIVE (status=${cluster_status}); nothing to reconcile"
  exit 0
fi

task_def_arn="$(aws ecs describe-services \
  --cluster "${CLUSTER}" \
  --services "${CANONICAL_SERVICE}" \
  --query 'services[0].taskDefinition' \
  --output text 2>/dev/null || echo "None")"

if [ "${task_def_arn}" = "None" ] || [ -z "${task_def_arn}" ]; then
  log "service ${CANONICAL_SERVICE} not found on ${CLUSTER}; nothing to reconcile"
  exit 0
fi

# Wait for the canonical service to settle before trusting its tag, so a
# mid-roll (or never-completing) deployment cannot leak a stale/unrun tag
# into SSM. In steady state this returns immediately. `if` keeps set -e
# from aborting before we can log the timeout.
log "waiting for ${CANONICAL_SERVICE} to reach a stable rollout before reading its tag"
if ! aws ecs wait services-stable --cluster "${CLUSTER}" --services "${CANONICAL_SERVICE}"; then
  log "ERROR: ${CANONICAL_SERVICE} did not reach a stable rollout; refusing to pin a possibly mid-roll image tag"
  exit 1
fi

# Re-read the task def now that the rollout has settled - the value read
# above predates the wait and could have been a desired-but-not-running
# revision.
task_def_arn="$(aws ecs describe-services \
  --cluster "${CLUSTER}" \
  --services "${CANONICAL_SERVICE}" \
  --query 'services[0].taskDefinition' \
  --output text)"

# Image looks like ".../cabal-imap:sha-abc12345". Strip everything
# before the last ':' to get the tag.
running_image="$(aws ecs describe-task-definition \
  --task-definition "${task_def_arn}" \
  --query "taskDefinition.containerDefinitions[?name=='${CANONICAL_CONTAINER}'] | [0].image" \
  --output text)"

if [ -z "${running_image}" ] || [ "${running_image}" = "None" ]; then
  log "could not read image from task def ${task_def_arn}; nothing to reconcile"
  exit 0
fi

running_tag="${running_image##*:}"

if [ -z "${running_tag}" ] || [ "${running_tag}" = "${running_image}" ]; then
  log "image ${running_image} has no tag separator; refusing to update SSM"
  exit 0
fi

ssm_tag="$(aws ssm get-parameter \
  --name "${SSM_PARAM}" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "MISSING")"

if [ "${ssm_tag}" = "MISSING" ]; then
  log "SSM parameter ${SSM_PARAM} does not exist; will be created by Terraform"
  exit 0
fi

if [ "${ssm_tag}" = "${running_tag}" ]; then
  log "SSM ${SSM_PARAM}=${ssm_tag} matches running ${CANONICAL_SERVICE}; no update"
  exit 0
fi

log "SSM ${SSM_PARAM}=${ssm_tag} but ${CANONICAL_SERVICE} runs ${running_tag}; updating SSM"
aws ssm put-parameter \
  --name "${SSM_PARAM}" \
  --value "${running_tag}" \
  --type String \
  --overwrite >/dev/null
log "SSM ${SSM_PARAM} now = ${running_tag}"

#!/usr/bin/env bash
#
# Roll every ECS service on cluster cabal-mail to the latest ACTIVE
# revision in its task-definition family. Phase 1 of
# docs/0.9.0/build-deploy-simplification-plan.md (shipped in 0.9.3)
# added lifecycle { ignore_changes = [task_definition] } to every
# aws_ecs_service so out-of-band app deploys are not rolled back by a
# topology-only Terraform apply. The downside: a Terraform topology
# change (cpu/memory/env/IAM) registers a new task-def revision, but
# the service stays pinned to the old one because Terraform is no
# longer authoritative on aws_ecs_service.task_definition.
#
# Phase 5 of the same plan introduces this script as a post-apply step
# in infra.yml. For each service we compare the family head against
# the service's current revision and update-service to the head when
# it has advanced. Out-of-band app deploys via deploy-ecs-service.sh
# already point the service at their freshly-registered revision, so
# in steady state this is a no-op.
#
# Failure modes:
#   - Cluster does not exist (first apply): exit 0, log a notice. No
#     services have been provisioned yet.
#   - list-services returns nothing: exit 0, log a notice.
#   - aws CLI fails for any other reason: exit non-zero.

set -euo pipefail

CLUSTER="${CLUSTER:-cabal-mail}"

log() { echo "[post-apply-update-services] $*"; }

cluster_status="$(aws ecs describe-clusters \
  --clusters "${CLUSTER}" \
  --query 'clusters[0].status' \
  --output text 2>/dev/null || echo "MISSING")"

if [ "${cluster_status}" != "ACTIVE" ]; then
  log "cluster ${CLUSTER} not ACTIVE (status=${cluster_status}); nothing to roll"
  exit 0
fi

service_arns="$(aws ecs list-services \
  --cluster "${CLUSTER}" \
  --output json \
  --query 'serviceArns' | jq -r '.[]')"

if [ -z "${service_arns}" ]; then
  log "no services on ${CLUSTER}; nothing to roll"
  exit 0
fi

rolled=0
unchanged=0

for service_arn in ${service_arns}; do
  service_name="${service_arn##*/}"

  current_td_arn="$(aws ecs describe-services \
    --cluster "${CLUSTER}" \
    --services "${service_name}" \
    --query 'services[0].taskDefinition' \
    --output text 2>/dev/null || echo "None")"

  if [ -z "${current_td_arn}" ] || [ "${current_td_arn}" = "None" ]; then
    log "${service_name}: no current task def; skipping"
    continue
  fi

  family="$(echo "${current_td_arn}" | awk -F/ '{print $NF}' | awk -F: '{print $1}')"
  current_rev="$(echo "${current_td_arn}" | awk -F: '{print $NF}')"

  latest_td_arn="$(aws ecs describe-task-definition \
    --task-definition "${family}" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text 2>/dev/null || echo "None")"

  if [ -z "${latest_td_arn}" ] || [ "${latest_td_arn}" = "None" ]; then
    log "${service_name}: cannot resolve family ${family}; skipping"
    continue
  fi

  latest_rev="$(echo "${latest_td_arn}" | awk -F: '{print $NF}')"

  if [ "${latest_rev}" = "${current_rev}" ]; then
    log "${service_name}: already on family head ${family}:${latest_rev}"
    unchanged=$((unchanged + 1))
    continue
  fi

  log "${service_name}: rolling ${family} from rev ${current_rev} to ${latest_rev}"
  aws ecs update-service \
    --cluster "${CLUSTER}" \
    --service "${service_name}" \
    --task-definition "${latest_td_arn}" >/dev/null
  rolled=$((rolled + 1))
done

log "summary: rolled=${rolled} unchanged=${unchanged}"

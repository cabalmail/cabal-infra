#!/usr/bin/env bash
#
# Pre-pull a freshly pushed image onto every ACTIVE container instance in
# the ECS cluster via SSM Run Command, while the old task is still
# serving. The IMAP service deploys with a zero-task window (single-task
# hard cap, see terraform/infra/modules/ecs/services.tf), and on a new
# SHA tag the image pull is by definition cold, so 30-60s of that window
# is pure layer download. Pulling ahead of the roll cuts it to ~zero.
# Phase 4 of docs/0.10.x/imap-deploy-downtime-plan.md.
#
# Fail-soft BY DESIGN: this script always exits 0 (except on missing
# args). A failed or skipped pre-pull just means deploy-ecs-service.sh
# runs on today's slow path; it must never block a deploy. That also
# covers the bootstrap case where the CI deploy principal does not yet
# have the SSM grants in an account (policies are hand-managed per
# account): the step logs a warning until the grants land.
#
# CI principal permissions used here (beyond the existing deploy set):
#   ecs:ListContainerInstances, ecs:DescribeContainerInstances,
#   ssm:SendCommand (AWS-RunShellScript + the cluster instances),
#   ssm:GetCommandInvocation
# The instance side is already in place: the container-instance role
# carries AmazonSSMManagedInstanceCore, and ECR pull rights come with
# AmazonEC2ContainerServiceforEC2Role.
#
# Usage:
#   prepull-image.sh <tier> <image_tag> [cluster]
#
# Env overrides:
#   PREPULL_TIMEOUT   seconds to wait for the remote pull (default 240)

set -euo pipefail

TIER="${1:?tier required}"
TAG="${2:?image_tag required}"
CLUSTER="${3:-cabal-mail}"
TIMEOUT="${PREPULL_TIMEOUT:-240}"

log() { echo "[prepull-image] $*"; }
warn_skip() { log "WARN: $* - skipping pre-pull; deploy proceeds on the slow path"; exit 0; }

if ! account_id="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then
  warn_skip "could not resolve account id"
fi
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[ -n "${region}" ] || warn_skip "AWS_REGION not set"

registry="${account_id}.dkr.ecr.${region}.amazonaws.com"
image="${registry}/cabal-${TIER}:${TAG}"

# -- Resolve the cluster's EC2 instance ids ---------------------

if ! ci_arns="$(aws ecs list-container-instances \
  --cluster "${CLUSTER}" \
  --status ACTIVE \
  --query 'containerInstanceArns' \
  --output text 2>/dev/null)"; then
  warn_skip "list-container-instances failed (missing IAM grant?)"
fi

if [ -z "${ci_arns}" ] || [ "${ci_arns}" = "None" ]; then
  warn_skip "no ACTIVE container instances in ${CLUSTER}"
fi

# shellcheck disable=SC2086  # ci_arns is a whitespace-separated ARN list
if ! instance_ids="$(aws ecs describe-container-instances \
  --cluster "${CLUSTER}" \
  --container-instances ${ci_arns} \
  --query 'containerInstances[].ec2InstanceId' \
  --output text 2>/dev/null)"; then
  warn_skip "describe-container-instances failed"
fi

log "pre-pulling ${image} on instance(s): ${instance_ids}"

# -- Issue the pull via SSM Run Command -------------------------
# The ECS-optimized AL2023 AMI ships the SSM agent and (normally) the
# AWS CLI; the dnf line is belt-and-suspenders for a minimal AMI. The
# instance role's ECR pull rights back the docker login.

remote_script="$(cat <<REMOTE
set -euo pipefail
command -v aws >/dev/null 2>&1 || dnf install -y -q awscli-2
aws ecr get-login-password --region ${region} | docker login --username AWS --password-stdin ${registry}
docker pull ${image}
REMOTE
)"

params="$(jq -cn --arg s "${remote_script}" '{commands: ($s | split("\n"))}')"

# shellcheck disable=SC2086  # instance_ids is a whitespace-separated list
if ! command_id="$(aws ssm send-command \
  --document-name AWS-RunShellScript \
  --instance-ids ${instance_ids} \
  --comment "pre-pull ${image} ahead of ECS roll" \
  --parameters "${params}" \
  --query 'Command.CommandId' \
  --output text 2>/dev/null)"; then
  warn_skip "ssm send-command failed (missing IAM grant?)"
fi

log "ssm command ${command_id} dispatched; waiting up to ${TIMEOUT}s"

# -- Wait for every instance to finish --------------------------

deadline=$(( $(date +%s) + TIMEOUT ))
for instance_id in ${instance_ids}; do
  while true; do
    status="$(aws ssm get-command-invocation \
      --command-id "${command_id}" \
      --instance-id "${instance_id}" \
      --query 'Status' \
      --output text 2>/dev/null || echo "Unknown")"
    case "${status}" in
      Success)
        log "${instance_id}: pull complete"
        break
        ;;
      Failed|Cancelled|TimedOut)
        warn_skip "${instance_id}: pull ${status}"
        ;;
      *)
        if [ "$(date +%s)" -ge "${deadline}" ]; then
          warn_skip "${instance_id}: still ${status} after ${TIMEOUT}s"
        fi
        sleep 10
        ;;
    esac
  done
done

log "pre-pull complete on all instances"

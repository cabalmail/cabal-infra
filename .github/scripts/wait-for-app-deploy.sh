#!/usr/bin/env bash
#
# Cross-workflow ordering gate for the infra.yml Terraform plan job.
#
# app.yml (out-of-band application deploy) and infra.yml (Terraform) are
# separate workflows with separate concurrency groups, so a single push
# that touches BOTH docker/** and terraform/infra/** runs them
# concurrently. infra.yml's plan job calls refresh-ssm-from-running.sh,
# which copies the image tag running on cabal-imap into
# /cabal/deployed_image_tag; Terraform's local.tier_image then builds
# every tier's task-def image from that one tag.
#
# The race (see CHANGELOG 0.10.9): app.yml spends minutes building images
# (and on prod waits at the gate-${env} approval) before
# deploy-ecs-service.sh rolls imap to the freshly-built tag. If infra.yml
# reaches refresh-ssm-from-running.sh first, it reads imap's PRE-ROLL
# (stale) tag, SSM keeps the old value, and any marker-triggered task-def
# re-registration in that same Terraform run (a *_taskdef_revision_marker
# bump in modules/ecs/task-definitions.tf) gets the new task def paired
# with the OLD image. In the incident a smtp-in capability-drop task def
# was paired with the pre-change image and the container died at startup,
# wedging the rollout.
#
# This script blocks the plan job until the app.yml run for THIS commit
# has finished, so by the time refresh-ssm-from-running.sh reads the tag,
# app.yml has already rolled imap to the new image AND waited for it to
# stabilize (deploy-ecs-service.sh now does aws ecs wait services-stable).
# That makes the read reflect what is actually deployed.
#
# Steady state is unaffected:
#   - terraform-only push: app.yml is not triggered (no matching paths),
#     so no run exists for this SHA and this script is a no-op.
#   - docker-only push: infra.yml is not triggered, so this never runs.
#   - workflow_dispatch infra run: operator-driven, not part of the push
#     race; skipped.
#
# By design this waits for the app.yml run as a whole, not just its docker
# job. A push that pairs a terraform change with a react/lambda-only app
# change will wait for that (image-irrelevant) app deploy too. That is the
# safe direction - over-waiting only costs latency, whereas guessing which
# app jobs touch images risks under-waiting and reopening the race - and
# such combined pushes are rare.
#
# Failure modes:
#   - event is not 'push': exit 0 (nothing to order against).
#   - gh CLI / token unavailable: exit 0 with a warning (do not wedge the
#     pipeline on tooling absence; the refresh-ssm stability gate is the
#     backstop).
#   - no app.yml run for this SHA after the appearance grace: exit 0
#     (app.yml was not triggered by this push).
#   - app.yml run completes (any conclusion): exit 0. A non-success
#     conclusion is logged; refresh-ssm-from-running.sh then reads
#     whatever actually deployed and is the arbiter of ECS state.
#   - app.yml run does not complete within WAIT_TIMEOUT: exit 1, so infra
#     does not plan against a possibly-stale tag while a deploy is still
#     in flight (e.g. a forgotten app approval). Approve/inspect the app
#     run, then re-run infra.

set -euo pipefail

SHA="${GITHUB_SHA:?GITHUB_SHA required}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
EVENT="${GITHUB_EVENT_NAME:-push}"
APP_WORKFLOW="${APP_WORKFLOW:-app.yml}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
# Both runs for a push are created together when GitHub evaluates the push
# event, and infra's plan job only reaches this script minutes later
# (after the changes + build jobs), so a triggered app.yml run is reliably
# visible by now. The grace only absorbs API read-replica lag, and it is
# the tax a terraform-only push (no app.yml run) pays before concluding
# there is nothing to wait for - keep it short.
APPEAR_GRACE="${APPEAR_GRACE:-20}"
# Cap the wait so a forgotten app.yml approval (or a hung app run) fails
# the infra plan instead of holding a runner for the 6h job ceiling.
WAIT_TIMEOUT="${WAIT_TIMEOUT:-3600}"

log() { echo "[wait-for-app-deploy] $*"; }

if [ "${EVENT}" != "push" ]; then
  log "event=${EVENT} (not push); no sibling app.yml run to wait for"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  log "gh CLI not available; cannot order against ${APP_WORKFLOW} - proceeding without wait"
  exit 0
fi

# Latest app.yml push run for this exact commit, as "id<TAB>status<TAB>conclusion".
# A re-run keeps the same head_sha, so head_sha scopes us to this push.
latest_run() {
  # `// empty` so an empty .workflow_runs yields no output (not a literal
  # "null" line from `null | tostring`), which is how the caller detects
  # "app.yml not triggered by this push".
  gh api -X GET "/repos/${REPO}/actions/workflows/${APP_WORKFLOW}/runs" \
    -f "head_sha=${SHA}" -f "event=push" -f "per_page=1" \
    --jq '.workflow_runs[0] // empty | [(.id|tostring), .status, (.conclusion // "")] | @tsv' 2>/dev/null || true
}

run_id=""
elapsed=0
while :; do
  line="$(latest_run)"
  if [ -n "${line}" ]; then
    run_id="$(printf '%s' "${line}" | cut -f1)"
    break
  fi
  if [ "${elapsed}" -ge "${APPEAR_GRACE}" ]; then
    log "no ${APP_WORKFLOW} push run for ${SHA} after ${APPEAR_GRACE}s; not triggered by this push, nothing to wait for"
    exit 0
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

log "found ${APP_WORKFLOW} run ${run_id} for ${SHA}; waiting up to ${WAIT_TIMEOUT}s for it to complete"

# Poll the specific run so a concurrently-started re-run cannot move the
# target out from under us mid-wait.
run_state() {
  gh api "/repos/${REPO}/actions/runs/${run_id}" \
    --jq '[.status, (.conclusion // "")] | @tsv' 2>/dev/null || true
}

elapsed=0
while :; do
  line="$(run_state)"
  status="$(printf '%s' "${line}" | cut -f1)"
  conclusion="$(printf '%s' "${line}" | cut -f2)"

  if [ "${status}" = "completed" ]; then
    log "${APP_WORKFLOW} run ${run_id} completed (conclusion=${conclusion:-unknown})"
    if [ "${conclusion}" != "success" ]; then
      log "WARNING: ${APP_WORKFLOW} did not succeed; refresh-ssm-from-running will read whatever actually deployed"
    fi
    exit 0
  fi

  if [ "${elapsed}" -ge "${WAIT_TIMEOUT}" ]; then
    log "ERROR: ${APP_WORKFLOW} run ${run_id} still '${status:-unknown}' after ${WAIT_TIMEOUT}s"
    log "refusing to plan against a possibly-stale image tag; approve/inspect the app run, then re-run infra"
    exit 1
  fi

  log "${APP_WORKFLOW} run ${run_id} status='${status:-unknown}'; waiting ${POLL_INTERVAL}s"
  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
done

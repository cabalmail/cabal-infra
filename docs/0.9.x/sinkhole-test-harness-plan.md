# SMTP Sinkhole Test Harness Plan

## Context

Cabalmail has no controllable way to produce a transient SMTP error against `smtp-out` on demand. The natural sources of 4xx responses - greylisting from real remote MTAs, transient DNS failures, rate-limited send paths - are either unreliable or only reproducible by accident. This becomes acute when validating queue-persistence behavior (see [smtp-out-queue-persistence-plan.md](smtp-out-queue-persistence-plan.md)): the phase 3 acceptance criteria require a queued message that survives task replacement, and the test sequence assumed in that plan does not exist as written.

Sending to a non-existent recipient on a live mail domain produces `550 5.1.1 User unknown` - a *permanent* failure that bounces immediately rather than queueing. Sending to a domain with no MX produces `5.1.2 host not found` - also permanent. Both are the wrong shape for queue-persistence testing, which needs a deferred message that sits in `/var/spool/mqueue` long enough for an operator to force a task replacement and observe handoff.

This plan adds a feature-flagged `sinkhole` ECS tier: a tiny SMTP listener that returns operator-configurable responses to every `RCPT TO`, reachable from `smtp-out` via Cloud Map plus a sendmail `mailertable` override. It is permanent infrastructure in the dev and stage environments, never enabled in prod, and is the test fixture that makes deferred-retry scenarios reproducible.

The first concrete use is queue-persistence phase 3 validation. Subsequent uses (DSN handling, large-message timeouts, STARTTLS-fallback behavior, multi-runner coordination once `confMIN_QUEUE_AGE` ships in phase 4) reuse the same fixture by toggling its response mode at runtime.

## Goals

- Produce a `421 4.3.2` (or other operator-selected) SMTP response on demand from a destination addressable by stage's `smtp-out`, without touching public DNS.
- Flip response behavior in real time from the AWS console (SSM Parameter Store) without redeploying the tier or restarting any task.
- Survive in stage as a permanent fixture (cheap, idle when not under test) so test sequences can run any time.
- Be impossible to enable in prod through any normal operator action.
- Reusable across test scenarios beyond queue persistence: permanent-error paths, accept-and-discard for traffic-shape testing, DSN handling, message-capture for inspection.

## Non-goals

- Replacing end-to-end integration tests against real remote MTAs. The sinkhole simulates *responses*, not real internet conditions; greylisting from a real Postfix is still a different signal.
- Load testing or fuzz testing. The listener is single-process Python and is not designed to absorb sustained traffic.
- Inbound testing of `smtp-in`. The harness is positioned downstream of `smtp-out`; inbound paths have their own surface and are out of scope here.
- Authenticated SMTP. The sinkhole accepts unauthenticated connections; it lives on a private subnet reachable only from within the VPC and is gated by a feature flag.
- TLS. The sinkhole does not offer STARTTLS in v1. `smtp-out` attempts STARTTLS opportunistically and falls back to plain when not offered; that fallback is itself a useful test signal. STARTTLS support can be added later if STARTTLS-specific queueing behavior needs to be exercised.
- Capturing message bodies to durable storage. The `accept-log` mode writes headers and envelope to CloudWatch Logs; no S3, no DynamoDB.

## Current state (audit)

- **No test fixtures in the codebase.** The `react/admin` and `lambda/api` tests are unit-level; `CabalmailKit` has `swift test`; nothing exercises the live SMTP path on the running cluster.
- **Cloud Map private DNS namespace.** [`aws_service_discovery_private_dns_namespace.mail`](../../terraform/infra/modules/ecs/service_discovery.tf:14) at `cabal.internal`. Currently registers `imap.cabal.internal` only. New tiers register here freely.
- **`smtp-out` mailertable generation.** [`docker/shared/generate-config.sh`](../../docker/shared/generate-config.sh) renders `/etc/mail/mailertable` from DynamoDB + env vars at task start and on SNS-triggered reconfigure. No test-domain entries today.
- **Quiesce mechanism.** [`docs/quiesce.md`](../quiesce.md) and `var.quiesced` already scale every mail tier's ECS service to zero. A new sinkhole tier picks up this behavior with one variable wire-through.
- **Feature-flag pattern.** `var.monitoring` ([`terraform/infra/variables.tf`](../../terraform/infra/variables.tf)) gates the entire monitoring stack at module scope. `var.sinkhole` follows the same shape.
- **ECR repo lifecycle.** [`terraform/infra/modules/ecr/main.tf`](../../terraform/infra/modules/ecr/main.tf) uses `prevent_destroy` on monitoring repos so toggling the flag off does not destroy historical images. Same posture for sinkhole.
- **Per-environment GitHub variables.** `vars.TF_VAR_MONITORING` is set per environment (prod/stage/development). `vars.TF_VAR_SINKHOLE` follows the same pattern; prod's value is hard-coded false and gated again by a Terraform `precondition` below.

## Target state

### New tier: `sinkhole`

- **Image.** `amazonlinux:2023` base, Python 3 from `dnf`, no third-party SMTP library. A `~80-line` `asyncio`-based listener on port 25 that:
  - Reads its response mode from an SSM Parameter on each connection (`/cabal/sinkhole_mode`, cached for 30 s to keep SSM call rate sane).
  - Implements modes:
    - `defer` (default): `421 4.3.2 Service temporarily unavailable` on every `RCPT TO`.
    - `bounce`: `550 5.1.1 User unknown` on `RCPT TO`.
    - `accept`: `250 OK` on `RCPT TO` and `354/250 OK` on `DATA`; body discarded.
    - `accept-log`: same as `accept` but writes envelope + headers (not body) to stdout, picked up by the awslogs driver.
    - `greylist`: first attempt from a given client IP returns 421; subsequent attempts within a 30-min window return 250. Simulates real greylisting.
  - On `MAIL FROM` and unknown verbs, responds per RFC 5321 minima. No EHLO extensions advertised in v1 (no PIPELINING, no STARTTLS, no SIZE).
- **ECR repository.** `cabal-sinkhole`, created with `prevent_destroy = true` so flag toggles do not destroy historical images. Builds happen via the `app.yml` docker matrix gated on `vars.TF_VAR_SINKHOLE == 'true'` (mirrors the existing monitoring-matrix logic).
- **ECS task definition + service.** `awsvpc`, EC2 launch type, 64MB memoryReservation / 128MB memory hard cap. Desired count 1, no autoscaling. Mounts no EFS, attaches no NLB target group - the only access path is Cloud Map. Carries the same `lifecycle { ignore_changes = [container_definitions] }` clause as the other tiers for build/deploy-simplification compatibility.
- **Cloud Map registration.** `aws_service_discovery_service.sinkhole` in the existing `cabal.internal` namespace, A-record TTL 10. Address: `sinkhole.cabal.internal`. Apply the same `terraform_data.<svc>_cloud_map_lifecycle` orphan-reconciliation pattern documented in [`service_discovery.tf:79`](../../terraform/infra/modules/ecs/service_discovery.tf:79).
- **SSM parameter.** `/cabal/sinkhole_mode`, type `String`, default value `defer`. Terraform creates it with `lifecycle { ignore_changes = [value] }` so operator changes via the console persist across applies.

### `smtp-out` integration

A single mailertable line activated when `SINKHOLE_ENABLED=true` is present in the `smtp-out` task's environment:

```
sinkhole.test       smtp:[sinkhole.cabal.internal]:25
```

`.test` is reserved by RFC 2606 and never resolves on the public internet, so a leaked packet has no escape path. The mailertable bracket-and-port syntax skips MX lookup entirely - `smtp-out` connects directly to the Cloud Map name. Cloud Map resolves it to the sinkhole task's ENI IP via the private VPC resolver.

[`generate-config.sh`](../../docker/shared/generate-config.sh) is extended with one conditional block that appends the line when the env var is set. The line is regenerated on every SNS-triggered reconfigure for free; no Docker rebuild needed if the flag flips at runtime.

When `var.sinkhole = true`, Terraform sets `SINKHOLE_ENABLED=true` in the `smtp_out` task definition's `environment` list. When false, the env var is omitted and `generate-config.sh` skips the mailertable line.

### Behavior when the flag is off

`var.sinkhole = false` is the default. With the flag off:

- No ECR repo (or the existing one persists via `prevent_destroy`, untouched).
- No task definition, no service, no Cloud Map registration.
- No `SINKHOLE_ENABLED` env var on `smtp-out`; mailertable has no `sinkhole.test` line.
- Sending to `anything@sinkhole.test` from a `var.sinkhole=false` environment produces a normal sendmail `host not found` failure on the public MX lookup for `.test`, which RFC 2606 guarantees never resolves. That is the correct shape: the harness simply does not exist in that environment.

### Prod safety

Two independent guardrails:

1. **GitHub Actions variable.** `vars.TF_VAR_SINKHOLE` is set per environment. Prod's value is fixed at `false` and never changed.
2. **Terraform `precondition`.** The sinkhole task definition carries a precondition that fails the plan if the resolved environment is `prod` and the flag is `true`:

   ```hcl
   precondition {
     condition     = !(var.sinkhole && var.environment == "prod")
     error_message = "Sinkhole tier must never run in prod."
   }
   ```

   The `var.environment` value is derived from the branch in the existing `infra.yml` flow; the precondition fires at plan time, before any resource is touched.

Belt and suspenders: even an accidental `TF_VAR_SINKHOLE=true` override on a prod apply fails the plan.

### Behavior toggling

Operator workflow during a test session:

```
aws ssm put-parameter --name /cabal/sinkhole_mode --value defer  --overwrite
# (drive smtp-out, observe queue)
aws ssm put-parameter --name /cabal/sinkhole_mode --value accept --overwrite
# (next retry delivers; queue drains)
```

The listener re-reads the parameter on every connection (cached 30 s). No task restart, no reconfigure SQS hop, no DNS change. The 30 s cache exists only to bound SSM API call rate; for a test session that wants tighter coupling, restart the sinkhole task to clear the cache.

### Quiesce behavior

The sinkhole tier wires into `var.quiesced` the same way other tiers do: when quiesced, desired count goes to zero. Coming out of quiesce, desired count goes back to 1. The Cloud Map registration persists (no instances registered while quiesced), so the mailertable on `smtp-out` continues to resolve to a name with no answers - which surfaces as a connection failure on the `smtp-out` side. That is the right shape for "sinkhole offline" test scenarios.

## Migration sequence

One PR per phase, in order. Each phase is independently apply-able and each phase's rollback is the previous phase.

1. **Plan doc.** This PR. No code, no infrastructure.
2. **Image.** Add [`docker/sinkhole/`](../../docker/sinkhole/) with a `Dockerfile` and `listener.py`. Wire into the `app.yml` docker matrix gated on `vars.TF_VAR_SINKHOLE`. ECR repo created Terraform-side in phase 3, so phase 2 alone cannot push - this PR introduces the buildable image and leaves it dormant.
3. **ECR + flag.** Add `var.sinkhole` and `var.environment` variables to `terraform/infra/variables.tf`. Add the `cabal-sinkhole` ECR repo with `prevent_destroy`. No tier resources yet. Plumb `vars.TF_VAR_SINKHOLE` and `vars.TF_VAR_ENVIRONMENT` through `infra.yml`. Phase 3 is safe to apply with the flag off everywhere.
4. **Tier.** Add the `sinkhole` task definition, ECS service, Cloud Map registration, SSM parameter, and orphan-reconciliation `terraform_data` to `terraform/infra/modules/ecs/`. Gated on `var.sinkhole`. Carry the prod-refusal `precondition`. Apply in dev first; flag stays off in stage and prod.
5. **`smtp-out` integration.** Add the conditional mailertable line in `generate-config.sh`. Add `SINKHOLE_ENABLED` env var on `smtp_out` task def, gated on `var.sinkhole`. After this lands and `var.sinkhole = true` is set in stage, a `smtp-out` reconfigure activates the route. Verify by sending a test message addressed to `nobody@sinkhole.test` from inside stage and observing the queued result.
6. **Runbook.** Add [`docs/testing/queue-persistence.md`](../testing/queue-persistence.md) with the step-by-step test sequence: enable in stage, set mode `defer`, send a message, force-replace a `smtp-out` task, observe handoff, set mode `accept`, wait for delivery, set mode back to `defer` (or scale sinkhole to zero) when done. Document the SSM commands, the `mailq` inspection via `aws ecs execute-command`, and the cleanup checklist.

### Per-environment ordering

`dev` end-to-end through phase 6, then `stage`. `prod` does not progress past phase 3 (the ECR repo is harmless to create; the tier itself is permanently gated off).

### Rollback

| Step | Rollback |
| --- | --- |
| Plan doc (1) | None needed - text only. |
| Image (2) | Delete the image directory. No infrastructure was created. |
| ECR + flag (3) | Terraform-side: delete the ECR resource (the `prevent_destroy` will block; remove the lifecycle clause first, then delete). The variables themselves can stay - they default to safe values. |
| Tier (4) | Set `var.sinkhole = false` in the target environment's GitHub variables and apply. Terraform destroys the tier cleanly; Cloud Map registration drains via the orphan-reconciliation pattern. Image and ECR repo persist. |
| smtp-out integration (5) | Revert `generate-config.sh` and remove the env var from the task def. A subsequent `smtp-out` reconfigure drops the mailertable line. |
| Runbook (6) | Delete the runbook file. |

## Operational considerations

- **Quiesce default.** Stage's sinkhole sits idle most of the time. Memory footprint is ~50MB; CPU is negligible. Worth leaving running rather than quiescing between tests - the cold-start cost of the listener is small but Cloud Map registration takes ~30 s to propagate, which is friction during back-to-back test runs.
- **SSM API call rate.** The 30 s cache in the listener bounds SSM calls to roughly two per minute per active TCP connection. A `defer`-mode test session has effectively zero rate; even a flood test would stay under SSM's per-second quotas.
- **CloudWatch Logs cost.** `accept-log` mode writes headers per message. Cost is bounded by the test volume; default is `defer` which writes only a one-line per-connection log entry.
- **Cross-tier isolation.** The sinkhole's task role grants `ssm:GetParameter` for `/cabal/sinkhole_mode` only; nothing else. The task ENI lives in the same private subnet as the mail tiers, with the same security-group ingress posture (port 25 from VPC CIDR). No outbound internet egress is needed - the listener does not initiate any connections.
- **Image rebuilds.** The sinkhole image rebuilds whenever the docker matrix fires with `vars.TF_VAR_SINKHOLE=true`. In stage that means roughly per-PR docker churn picks it up; in dev with the flag off it never builds. Build cost is small (~30 s for the layer cache, ~5 s for the application copy).
- **Diagnosing "queue not draining" during a real outage.** If an operator forgets to flip the sinkhole back to `accept` after a test, real outbound mail addressed to `sinkhole.test` (which should be zero - no production code generates such addresses) would queue indefinitely. Mitigation: a one-line filter in the existing CloudWatch alarms watches for `sinkhole.test` in `smtp-out` queue-add log lines. Documented in the runbook as part of cleanup.

## Acceptance

- Stage with `var.sinkhole = true` and `/cabal/sinkhole_mode = defer` queues a test message sent to `anything@sinkhole.test`, with the queued message visible in `mailq` on every running `smtp-out` task.
- Setting the SSM parameter to `accept` and waiting for the next queue run (max 15 min on phase 3, max 5 min after phase 4) results in the message being delivered and removed from the queue.
- Prod with any combination of `var.sinkhole=true` set out-of-band fails the Terraform plan at the `precondition` stage; no resources are created.
- Disabling the flag in stage (`var.sinkhole = false`) destroys the sinkhole tier cleanly, leaves the ECR repo intact, removes the `SINKHOLE_ENABLED` env var from `smtp-out`, and on the next `smtp-out` reconfigure drops the mailertable line. Subsequent test sends fail with public-DNS host-not-found, the expected "harness not installed" shape.
- A queue-persistence phase 3 test sequence (defer mode + force-replace `smtp-out` task) demonstrates message survival across task replacement, satisfying acceptance criterion 1 of the queue-persistence plan.

## Open questions

- **Should the sinkhole offer STARTTLS in v1?** Probably not. `smtp-out` falls back to plain when STARTTLS is not advertised, and that fallback is itself a useful test signal. Add STARTTLS support if and when a test needs to exercise the encrypted-channel path specifically. Tracked as a follow-up, not a blocker.
- **Should `accept-log` mode write to S3 instead of CloudWatch?** CloudWatch is enough for envelope + headers; S3 would matter if we ever want to retain full message bodies for offline analysis. Decide if/when that need is concrete.
- **Should sinkhole modes be per-connection-IP rather than global?** The `greylist` mode is implicitly per-IP. Adding a more general "respond differently per source" would be useful for testing multi-tenant scenarios but is over-engineered for v1. Defer.
- **Mailertable line for `smtp-in` testing too?** `smtp-in` does not initiate outbound delivery, so it has no mailertable to consult. If we ever want to test inbound paths against the sinkhole (e.g. delivery loops), the routing is different and a separate fixture may be warranted.
- **Naming.** `sinkhole` is descriptive but slightly pejorative. `mocksmtp`, `smtp-mock`, `smtp-test` are alternatives. Bikeshed during phase 2 if it matters; the tier name is internal-only and easy to rename if the docker matrix axis is the only consumer.

## Out of scope

- Inbound (`smtp-in`) test fixtures.
- IMAP / submission test fixtures.
- Web UI for inspecting captured messages.
- Cross-environment chained testing (stage's `smtp-out` to dev's sinkhole, etc.).
- Replacing the existing alarm/heartbeat surface; the sinkhole does not double as a monitoring probe.

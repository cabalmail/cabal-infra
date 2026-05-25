# IMAP Deploy Downtime Reduction Plan

## Context

Every deploy to the IMAP tier produces roughly 2-4 minutes of client-facing IMAP unavailability. The cause is structural: the IMAP service is hard-pinned at one container at a time because Dovecot is configured for single-server operation against the EFS-backed Maildir, and the deployment shape is therefore "stop old, start new" with a gap in between. The current tuning of NLB health checks and the entrypoint script lengthens that gap further than it needs to be.

Mail safety is the binding constraint. Inbound mail is already protected during the gap by smtp-in's `/etc/hosts` IMAP pin plus sendmail's 4-day retry behaviour on TCP timeout ([`docker/shared/entrypoint.sh:185-189`](../../docker/shared/entrypoint.sh)); the visible impact is purely IMAP client sessions dropping for a few minutes. The single-Dovecot-at-a-time invariant is correct given today's Dovecot config and there is no proposal here to weaken it. This plan attacks the gap *within* that invariant.

A separate, riskier path - reconfiguring Dovecot for NFS-safe multi-instance operation so brief overlap is safe and `min_healthy=100, max=200` rolling deploys become legal - is explicitly out of scope for 0.10.x. See "Future work" below.

## Goals

- IMAP unavailability during a clean deploy drops from 2-4 minutes to under 90 seconds (target: 30-60 seconds).
- The "never two Dovecots writing the same Maildir" invariant is preserved bit-for-bit. No change to [`docker/imap/configs/dovecot/10-mail.conf`](../../docker/imap/configs/dovecot/10-mail.conf). No change to `deployment_minimum_healthy_percent` / `deployment_maximum_percent` on the IMAP service.
- Each phase is independently revertible. Any phase can be abandoned without affecting the others.
- Failed deploys (bad image, bad secrets, bad entrypoint) are detected before the old IMAP task is stopped, bounding worst-case downtime.
- No change to inbound mail handling. smtp-in's pin-and-retry behaviour continues to absorb the gap for SMTP delivery.

## Non-goals

- Reconfiguring Dovecot for NFS-safe multi-instance operation (`mail_nfs_storage=yes`, `mail_nfs_index=yes`, `mmap_disable=yes`, etc.). This is the only path to sub-second IMAP failover and is its own initiative with its own risk profile; tracked under "Future work."
- Dovecot director. Director only pays off when more than one IMAP backend runs steady-state; it is not the right shape for a deploy-only-overlap use case.
- Blue/green via two ECS services and NLB listener swaps. Same overlap problem as relaxing `min_healthy`; same out-of-scope reason.
- Image content slimming (Alpine base, multi-stage builds, etc.). The image pull is one component of the gap, but slimming the AL2023-based image is a larger project. Pre-pulling addresses the same symptom for less work.
- Changes to smtp-in or smtp-out deploy behaviour. Those tiers already deploy with `min_healthy=100, max=200` ([`terraform/infra/modules/ecs/services.tf:74-75,111-112`](../../terraform/infra/modules/ecs/services.tf)) and are not the concern.

## Current state (audit)

### The single-Dovecot invariant

The invariant is enforced in three places that must remain unchanged:

[`terraform/infra/modules/ecs/services.tf:11-25`](../../terraform/infra/modules/ecs/services.tf):

```hcl
# IMAP: Hard-capped at one container. Dovecot has concurrency issues with
# shared Maildir over EFS, so there must never be more than one IMAP task.
resource "aws_ecs_service" "imap" {
  desired_count = var.quiesced ? 0 : 1
  # No extra task during deploy - only one IMAP container at a time.
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0
}
```

[`docker/imap/configs/dovecot/10-mail.conf:1-8`](../../docker/imap/configs/dovecot/10-mail.conf):

```
mail_location = maildir:~/Maildir
mail_fsync = always
# We actually *are* using NFS, but these are the recommended settings for a single IMAP server
mail_nfs_storage = no
mail_nfs_index = no
maildir_copy_with_hardlinks = yes
mbox_write_locks = fcntl
```

The IMAP task definition does not set `stopTimeout`, so the ECS default of 30 seconds applies ([`terraform/infra/modules/ecs/task-definitions.tf:20-94`](../../terraform/infra/modules/ecs/task-definitions.tf)). This is fine - Dovecot has no heavy in-flight work to drain.

### Where the gap comes from

The cold-start budget, in deploy order:

1. **ECS stops the old task.** SIGTERM, 30 s grace, SIGKILL.
2. **ECS schedules and pulls the image.** On a cold image-layer cache, full pull of the AL2023-based image is 30-60 s. On warm cache (re-rolling the same tag) the pull is near-zero.
3. **Entrypoint runs 12 sequential steps.** [`docker/shared/entrypoint.sh:40-193`](../../docker/shared/entrypoint.sh). All synchronous, all before supervisord starts Dovecot:
   - Step 1: TLS cert write.
   - Step 2: sendmail.mc template render.
   - Steps 3-4: cognito.bash + dovecot SSL conf.
   - Step 5: [`sync-users.sh`](../../docker/shared/sync-users.sh) - Cognito `list-users` plus a per-user `install -d` EFS round-trip.
   - Step 6: [`generate-config.sh`](../../docker/shared/generate-config.sh) - full DynamoDB scan of `cabal-addresses` and sendmail map rebuild.
   - Step 7: `make -C /etc/mail` (sendmail.cf compile).
   - Step 8: `newaliases`.
   - Step 9: `htpasswd` for the Dovecot master user.
   - Steps 10-12: fail2ban config, rsyslog dir, `/etc/hosts` pin (smtp-in only, skipped here).
   - Step 13: `exec supervisord`.
4. **supervisord starts Dovecot at `priority=20`**, after sendmail at `priority=10`. No `startsecs` guard. ([`docker/imap/supervisord.conf:29-35`](../../docker/imap/supervisord.conf))
5. **NLB health check declares the target healthy.** TCP probe every 30 s, `healthy_threshold=2`. Best-case 60 s from Dovecot listening to "in service."
6. **Existing clients reconnect.** Many will retry on a backoff; some will require manual nudging if the gap was long enough.

### NLB and ECS tuning

[`terraform/infra/main.tf:197-199`](../../terraform/infra/main.tf):

```hcl
health_check_grace_period = 600
deregistration_delay      = 120
unhealthy_threshold       = 10
```

These read as debug-friendly defaults, not production deploy tunings:

- `unhealthy_threshold = 10` x `interval = 30` means a *broken* task stays in service for five minutes before NLB removes it. That is intentional (operator-friendly: "let me ssh in and look before it disappears"). The catch: the interval and healthy_threshold also control how long a *newly healthy* task waits to be rotated in.
- `deregistration_delay = 120` has no effect on the IMAP service today. With `min_healthy=0, max=100`, there is no second task to drain into; the old task is stopped before the new one registers.
- `health_check_grace_period = 600` means ECS will wait ten minutes before declaring a stuck new task failed and rolling back the deploy. Again debug-friendly, not deploy-friendly.

[`terraform/infra/modules/ecs/target_groups.tf:9-30`](../../terraform/infra/modules/ecs/target_groups.tf):

```hcl
resource "aws_lb_target_group" "tier" {
  health_check {
    interval            = 30
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = var.unhealthy_threshold
  }
  stickiness {
    type    = "source_ip"
    enabled = true
  }
}
```

### Inbound mail safety during the gap

smtp-in pins the IMAP-task IP in `/etc/hosts` at entrypoint and refreshes it via [`hosts-pin.sh`](../../docker/shared/hosts-pin.sh) ([`docker/shared/entrypoint.sh:177-189`](../../docker/shared/entrypoint.sh)). When the IMAP container is mid-deploy, smtp-in's sendmail attempts delivery, gets TCP connection refused / timeout, and queues for retry. Sendmail's default queue retry window is ~4 days. No bounces, no lost mail. This already-correct behaviour is one reason the visible impact of the deploy gap is bounded to IMAP client UX, not delivery.

## Plan

Five phases. Phases 1-2 are tuning changes only; phase 3 is the largest code change; phases 4-5 are deploy-pipeline additions. Each is independently revertible.

Implementation order is recommended but not strict. Phase 1 is the highest-leverage single change; phase 3 is the largest absolute win on container-side cold start.

### Phase 1: Tighten NLB health-check schedule for IMAP

**Change.** Lower the NLB health-check interval for the IMAP target group from 30 s to 10 s. Keep `healthy_threshold=2`. Keep `unhealthy_threshold=10` on the IMAP target group so a broken task stays visible to the operator for the same wall-clock duration as today.

**Why.** `healthy_threshold=2` x `interval=30s = 60s` worst-case from Dovecot listening to in-service. With interval=10s that becomes ~20s. The same change applied to a broken task means `unhealthy_threshold=10` x `interval=10s = 100s` instead of 300s before NLB removes it - acceptable trade-off for the deploy speedup. If the operator-debugging window matters more, bump `unhealthy_threshold` to 30 to preserve the 300s out-of-service grace.

**Implementation.** Per-target-group health-check overrides. Either:
1. Add a `health_check_interval` field to the `local.target_groups` map in [`terraform/infra/modules/ecs/locals.tf`](../../terraform/infra/modules/ecs/locals.tf) and reference it from [`target_groups.tf`](../../terraform/infra/modules/ecs/target_groups.tf), defaulting to 30 for non-IMAP tiers; or
2. Add a top-level `imap_health_check_interval` variable to the ECS module.

Option 1 generalises better. Option 2 is faster to write.

**Risk.** Lower-interval probes are 3x the request volume. NLB charges per "LCU" but the TCP-probe contribution is negligible; cost impact is zero in practice. Dovecot's per-connection log floor was already addressed by the `login_trusted_networks` setting ([`docker/shared/entrypoint.sh:116-121`](../../docker/shared/entrypoint.sh)), so no new log noise.

**Revert.** Set the field back to 30.

**Estimated savings.** 40 s per deploy.

### Phase 2: Drop `health_check_grace_period` for IMAP

**Change.** Lower the IMAP service's `health_check_grace_period` from 600 s to 120 s.

**Why.** 600 s gives a stuck IMAP task 10 minutes before ECS gives up on it and lets the deployment circuit breaker (if configured) roll back. That is appropriate for "let me debug a flaky entrypoint in real time" and not for "fail fast on a bad deploy so I can fix it." 120 s comfortably covers image pull + entrypoint + Dovecot startup on a healthy task.

**Implementation.** Either thread a separate `imap_health_check_grace_period` through the ECS module or split the `health_check_grace_period` variable into per-tier values. The other tiers (smtp-in, smtp-out) use the same value today; check whether they want the same drop or not.

**Risk.** A truly slow cold start (huge image pull, EFS latency spike, Cognito throttling on `list-users`) could blow past 120 s and cause ECS to kill the new task. Pair with the deployment circuit breaker (`deployment_circuit_breaker { enable = true, rollback = true }`) so the failure mode is "deploy rolls back" rather than "thrash." Test in stage before prod.

**Revert.** Set it back to 600.

**Estimated savings.** None on success path - this is a failure-mode improvement. Reduces blast radius of stuck deploys.

### Phase 3: Start Dovecot earlier in the entrypoint

**Change.** Restructure [`docker/shared/entrypoint.sh`](../../docker/shared/entrypoint.sh) on the IMAP tier so Dovecot can start as soon as its dependencies are satisfied, with the sendmail-side preparation continuing in the background.

**Why.** Dovecot needs steps 1 (TLS), 4 (SSL conf), 5 (sync-users so user accounts exist), 9 (master htpasswd). Dovecot does *not* need steps 2 (sendmail.mc render), 6 (DynamoDB → sendmail maps), 7 (`make -C /etc/mail`), 8 (`newaliases`). Steps 2, 6, 7, 8 are the sendmail-on-port-25 local-delivery path, which is what smtp-in talks to.

Today's order is "do all of it, then start supervisord." A smarter order is:
- Do steps 1, 4, 5, 9 (Dovecot prerequisites) synchronously.
- `exec supervisord` so Dovecot is up and listening.
- Have supervisord run a "post-start" program that does steps 2, 6, 7, 8 (sendmail prerequisites), then starts sendmail.

This is a clean supervisord pattern: split the IMAP container's startup into two priority bands instead of one big entrypoint script.

**Implementation.** Two options, in order of preference:

1. **Move sendmail prep into a `prepare-sendmail` supervisord program** with `priority=5, autorestart=false, startsecs=0, exitcodes=0`. Have the existing `sendmail` program depend on it via supervisord's start ordering (priority). Add a sentinel file (`/run/sendmail-ready`) and have `sendmail-wrapper.sh` block on it. This way Dovecot (priority=20) and the sendmail prep (priority=5) come up in parallel, sendmail itself (priority=10) waits for prep. Note: this slightly reorders priorities; verify `rsyslog` (priority=1) and `log-tailer` (priority=2) still come up first.

2. **Background the slow steps from entrypoint.sh.** Run steps 6+7+8 with `&` and then `exec supervisord`. Less clean - supervisord is now competing with a backgrounded shell process for the PID-1 reap - but smaller diff.

Option 1 is the right shape; option 2 is the smaller PR if time-boxed.

**Side effects to watch.**

- The smtp-in tier delivers to the IMAP container's sendmail on port 25 ([`task-definitions.tf:125`](../../terraform/infra/modules/ecs/task-definitions.tf) for the service-discovery wiring). During the window where Dovecot is up but sendmail-prep is still running, smtp-in's sendmail will see TCP connection refused on port 25 and queue. Same retry-window behaviour that already absorbs the deploy gap; no bounces.
- `newaliases` writes to `/etc/aliases.db`, which is in the container filesystem, not on EFS. Safe to defer.
- `htpasswd -b -c -s /etc/dovecot/master-users` (step 9) must run *before* Dovecot starts or the master-user auth path silently fails. Verify this is in the "Dovecot prerequisites" bucket.

**Risk.** Subtle ordering bugs - especially if sync-users is moved or split. Dovecot started before sync-users completes means a user that logged in during the gap window gets "no such user" until sync finishes. Keep sync-users on the synchronous critical path.

**Revert.** Single-file revert of [`docker/imap/supervisord.conf`](../../docker/imap/supervisord.conf) plus [`docker/shared/entrypoint.sh`](../../docker/shared/entrypoint.sh).

**Estimated savings.** 20-40 s per deploy, depending on DynamoDB scan latency.

### Phase 4: Pre-pull the new image to the ECS instance

**Change.** Before [`deploy-ecs-service.sh`](../../.github/scripts/deploy-ecs-service.sh) calls `aws ecs update-service`, run `docker pull` against the EC2 instance(s) hosting the cabal-mail cluster via SSM Run Command.

**Why.** Image pull happens after the old task is stopped and before the new task can start. On a cold cache (which is the deploy case by definition - new SHA tag) that is 30-60 s of pure wall-clock gap. Pulling while the old container is still serving cuts this to zero.

**Implementation.** Add a step to the `docker` job in [`.github/workflows/app.yml`](../../.github/workflows/app.yml) that:

1. Discovers the ECS-instance IDs in the cabal-mail cluster (one in normal operation; capacity provider may have spares).
2. Issues `aws ssm send-command --document-name AWS-RunShellScript --instance-ids ... --parameters 'commands=["docker pull <ecr-uri>:<tag>"]'`.
3. Waits for command completion (or fire-and-forgets - a failed pull just means the existing slow-path runs).
4. Then proceeds to `deploy-ecs-service.sh`.

The ECS instance role needs ECR pull permission (it already has this for normal operation). The deploy workflow needs `ssm:SendCommand` and `ssm:GetCommandInvocation`. Verify the CI deploy IAM role has these; add if not.

**Risk.** Almost none. Failure to pre-pull silently degrades to current behaviour. Disk pressure on the EC2 instance is the only real concern; if the cluster ever runs at near-full ECR cache, pre-pulling adds a layer's worth of disk per deploy. ECS already prunes; should not matter at this scale.

**Revert.** Remove the workflow step.

**Estimated savings.** 30-60 s per deploy on cold-layer cache. Zero on warm cache (re-rolling the same tag).

### Phase 5: Pre-flight the new task off the load balancer

**Change.** Before `aws ecs update-service` rolls the IMAP service, run the new task as a standalone one-shot ECS task that exercises the entrypoint and exits non-zero on failure. Only if it succeeds, proceed to update the service.

**Why.** Today, a bad image (broken entrypoint, missing secret, etc.) is discovered by stopping the old task and then watching the new one fail. That is the worst time to discover it: IMAP is unavailable for the full debug+rollback window. Pre-flight finds the failure while the old task is still serving.

**Implementation.** Two shapes:

1. **One-shot RunTask.** Register a separate task-definition family (e.g. `cabal-imap-preflight`) that uses the same image and secrets but overrides the entrypoint to a script that does steps 1-9 of [`entrypoint.sh`](../../docker/shared/entrypoint.sh) and exits 0. RunTask, wait, check exit code. Deploy only on success.
2. **Lighter: validate-only entrypoint flag.** Add a `PREFLIGHT=1` env var to entrypoint.sh; when set, it runs steps 1-9 and exits 0 instead of `exec supervisord`. Deploy script calls RunTask with `PREFLIGHT=1` overlaid via `--overrides`, waits, then proceeds. No second task-definition family.

Option 2 is much smaller. Use it.

**Risk.** Adds 30-60 s to the *successful* deploy path (the preflight task has to start, pull image - but the layer is now cached from phase 4 - run entrypoint, exit). For the failure path, saves the full 2-4 minute outage. Net win on average if the deploy-failure rate is above ~2%. Today that rate is realistically higher than 2% for IMAP-touching changes.

**Revert.** Remove the workflow step. The `PREFLIGHT=1` branch in entrypoint.sh is dead code but harmless.

**Estimated savings.** Zero on success path; full deploy-gap (~2-4 min) on failure path.

## Combined estimated downtime

| Stage                        | Today      | After phases 1+3+4 |
| ---------------------------- | ---------- | ------------------ |
| Old task stop                | 0-30 s     | 0-30 s             |
| Image pull                   | 30-60 s    | ~0 s (pre-pulled)  |
| Entrypoint synchronous work  | 30-60 s    | 10-20 s            |
| Dovecot start                | 5-10 s     | 5-10 s             |
| NLB declare healthy          | 30-60 s    | 10-20 s            |
| **Total IMAP unavailability** | **~2-4 min** | **~30-90 s**     |

Phase 2 contributes nothing to the success-path budget but lowers worst-case failure-path downtime. Phase 5 trades ~30-60s on every successful deploy for catching failures *before* the cutover instead of *during*; net win if failure rate stays non-trivial.

## Risks and rollback

Per phase above. Phases 1, 2, 4 are pure config / pipeline changes and revert with a single commit. Phase 3 is the largest behaviour change; the supervisord split should be exercised in stage for at least a week before promoting to prod. Phase 5 changes the deploy workflow shape and should be exercised end-to-end (with a deliberately broken image) once in dev before stage.

None of the five phases relax the single-Dovecot invariant. If any phase produces a regression that looks like Dovecot concurrency (index corruption, Maildir inconsistency, lost flag state), revert and assume the invariant was somehow violated - that is the highest-priority signal.

## Future work

When the project is ready to genuinely overlap two IMAP tasks during deploys (sub-second failover, NLB connection draining doing real work), the path is:

1. Switch [`docker/imap/configs/dovecot/10-mail.conf`](../../docker/imap/configs/dovecot/10-mail.conf) to the NFS-multi-server profile:
   - `mail_nfs_storage = yes`
   - `mail_nfs_index = yes`
   - `mmap_disable = yes`
   - `mail_fsync = always` (already set)
   - `lock_method = fcntl` (already implied)
   - `dotlock_use_excl = no`
2. Flip the ECS IMAP service to `min_healthy=100, max=200` so rolling deploys put the new task up before stopping the old one.
3. `deregistration_delay=120` starts doing real work (connection draining for live IMAP sessions). Lower it to something deploy-appropriate (~30 s) once draining is verified.

The trade-offs to validate beforehand: index cache invalidation latency on EFS (read-after-write consistency is close-to-open in NFSv4.1; Dovecot's NFS code expects this but corner cases exist around fcntl locking and timestamp coarseness), perf impact of `mail_fsync=always` + `mmap_disable=yes` on EFS at our message volume, and what happens when EFS has a hiccup mid-deploy and both Dovecots momentarily disagree on index state. Dovecot in this mode is well-trodden ground in the industry but is not the default and deserves its own plan, its own stage soak, and its own rollback procedure.

This work would slot into a future minor version after 0.10.x ships and the Tier 1 changes are in steady state.

# SMTP-OUT Queue Persistence Plan

## Context

The `smtp-out` tier accepts authenticated submissions on 465/587, signs with DKIM, and hands off to remote MTAs via sendmail. When sendmail can't deliver immediately — the most common cause is a remote 4xx (greylisting, rate limit, transient DNS, recipient deferral) — the message lands in `/var/spool/mqueue/` and the in-process queue runner retries on a `-q15m` cadence with a `confTO_QUEUERETURN` bounce horizon of 4 days (see [`out-sendmail.mc:9`](../../docker/templates/out-sendmail.mc:9)).

Today that queue lives on the container's ephemeral writable layer. ECS replaces tasks for ordinary reasons — image deploys, host draining, scale-in events, EC2 instance recycling — and any queued message in a replaced task is silently lost. The user never sees a bounce, the recipient never sees the mail, and the only signal is the absence of the eventual delivery. Greylisting in particular guarantees a deferral on first contact with most well-configured remote MTAs, so the window of exposure is not hypothetical: it overlaps with every deploy.

This plan persists the sendmail MTA queue on a new EFS access point on the existing `mailstore` filesystem, mounted by every `smtp-out` task. With the queue on shared storage, a replaced task hands off its in-flight retries to whichever sibling task next scans the queue, and a freshly-launched task picks up where its predecessor left off. Sendmail's classic shared-NFS queue pattern (multiple MTAs running queue runners against one spool, coordinated by `fcntl` locks on each `qf*` file) provides the correctness guarantee.

## Goals

- A message accepted by `smtp-out` and queued for retry survives task replacement, scale-in, and host failure.
- Multiple concurrent `smtp-out` tasks (current autoscale is 1–3) safely share one queue without double-delivery.
- A draining task is given enough time to finish in-flight deliveries before SIGKILL, so persistent queue acts as the safety net rather than the primary mechanism.
- Operators can inspect the shared queue from any `smtp-out` task with `mailq` and dequeue stuck messages with the usual sendmail tooling.
- No regression for the `imap` tier, which already mounts the same EFS filesystem at `/home`.

## Non-goals

- Persisting `mqueue-client` (the local submit-program spool). The `smtp-out` image runs only `sendmail.cf`; `submit.cf` is not configured (see [`Dockerfile:39`](../../docker/smtp-out/Dockerfile:39) and [`out-sendmail.mc`](../../docker/templates/out-sendmail.mc)). Local-only client submissions don't traverse the deferred-retry path that motivates this work.
- Persisting queues for `smtp-in` or `imap`. Inbound relay drops are bounced upstream, not queued for our retry; IMAP local delivery is synchronous to the EFS-backed mailstore.
- Hardening the existing `cabal-efs-sg` ingress rule. It currently allows NFS from the entire VPC CIDR ([`efs/main.tf:21`](../../terraform/infra/modules/efs/main.tf:21)); tightening to specific task SGs is a separate posture decision and out of scope here.
- Migrating IMAP off its current `root_directory = "/"` mount onto an access point. The two patterns coexist on the same filesystem fine; aligning them is a future cleanup, not a prerequisite.
- Replacing sendmail with another MTA. The shared-queue pattern is sendmail-native and is the entire reason this approach is straightforward.

## Current state (audit)

- **EFS filesystem:** single `aws_efs_file_system.mailstore` ([`efs/main.tf:5`](../../terraform/infra/modules/efs/main.tf:5)), encrypted at rest, 30-day IA lifecycle, mount targets in every private subnet. No access points defined.
- **EFS security group:** `cabal-efs-sg` permits NFS (2049) from the full VPC CIDR ([`efs/main.tf:15`](../../terraform/infra/modules/efs/main.tf:15)). No change needed for `smtp-out` — its tasks run inside the same VPC.
- **`smtp-out` task definition:** [`task-definitions.tf:147`](../../terraform/infra/modules/ecs/task-definitions.tf:147). No `volume` block, no `mountPoints`, no EFS plumbing today. Shares `aws_iam_role.ecs_task` with the other tiers.
- **`smtp-out` ECS service:** `desired_count` autoscaled 1–3 on CPU 70%, `min_healthy_percent=100`, `max_percent=200`. ECS task `stopTimeout` is unset (defaults to 30s).
- **Sendmail invocation:** [`sendmail-wrapper.sh:12`](../../docker/shared/sendmail-wrapper.sh:12) — `exec /usr/sbin/sendmail -bD -q15m`. The `exec` is important: SIGTERM from supervisord reaches sendmail directly, not the wrapper.
- **Supervisord sendmail program:** [`smtp-out/supervisord.conf:19-27`](../../docker/smtp-out/supervisord.conf:19) — `stopwaitsecs=15`. Supervisord sends SIGTERM and then SIGKILL after 15s.
- **Sendmail `.mc` template:** [`out-sendmail.mc`](../../docker/templates/out-sendmail.mc). Uses default queue path (`/var/spool/mqueue`); `confTO_QUEUERETURN=4d`, `confTO_QUEUEWARN=4h`. No `MIN_QUEUE_AGE` or shared-queue tuning.
- **Entrypoint:** [`docker/shared/entrypoint.sh`](../../docker/shared/entrypoint.sh) does not touch `/var/spool/mqueue` (verified via grep). No fresh-init or wipe to gate.

## Target state

### EFS access point

A new access point on the existing `mailstore` filesystem, scoped to `/smtp-queue`:

```hcl
resource "aws_efs_access_point" "smtp_queue" {
  file_system_id = aws_efs_file_system.mailstore.id

  root_directory {
    path = "/smtp-queue"
    creation_info {
      owner_uid   = 0      # root
      owner_gid   = 25     # smmsp on AL2023 sendmail packaging — verify in image
      permissions = "0750"
    }
  }

  tags = {
    Name = "cabal-smtp-queue"
  }
}
```

**No POSIX user override.** Sendmail manages ownership across the `qf` (control), `df` (data), `xf` (transcript), and `tf` (temp) files itself; an enforced uid/gid on the access point would break the privilege drops between the listener (root) and queue runner (`smmsp`). The access point only enforces the root-directory boundary and the initial creation owner; sendmail's own perms govern the rest.

The 25 in `owner_gid` reflects the historic `smmsp` group id under sendmail's RPM packaging. **The first PR in the migration sequence below verifies the actual gid in the running smtp-out image** (`getent group smmsp`) before the access point is created, and adjusts if AL2023 packaging differs.

### ECS task-definition changes

In [`task-definitions.tf`](../../terraform/infra/modules/ecs/task-definitions.tf), the `smtp_out` task definition gains a `volume` block and the container gains a `mountPoints` entry:

```hcl
resource "aws_ecs_task_definition" "smtp_out" {
  # ... existing fields ...

  container_definitions = jsonencode([{
    # ... existing fields ...
    stopTimeout = 120

    mountPoints = [{
      sourceVolume  = "smtp-queue"
      containerPath = "/var/spool/mqueue"
    }]
  }])

  volume {
    name = "smtp-queue"
    efs_volume_configuration {
      file_system_id     = var.efs_id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = var.smtp_queue_access_point_id
        iam             = "DISABLED"
      }
    }
  }
}
```

`iam = "DISABLED"` matches the IMAP mount's posture today (no IAM auth on EFS). The access point itself is the path/uid boundary; IAM auth is a defense-in-depth layer we can add later for both mounts in one pass. `transit_encryption = "ENABLED"` is the safe default and has negligible perf impact on small files.

`stopTimeout = 120` is the ECS-task-level grace window (max useful value; ECS hard-caps at 120s for EC2 launch type). Combined with the supervisord change below, this gives sendmail up to ~110 seconds to finish an in-flight delivery before SIGKILL.

The `efs` module exposes the new access point id as an output (`smtp_queue_access_point_id`); the root module wires it through to the `ecs` module.

### Container runtime changes

- [`smtp-out/supervisord.conf:26`](../../docker/smtp-out/supervisord.conf:26): raise `stopwaitsecs` from `15` to `110`.
- [`docker/shared/sendmail-wrapper.sh`](../../docker/shared/sendmail-wrapper.sh): defensive `chown root:smmsp /var/spool/mqueue && chmod 0750` immediately before the `exec`. The access point's `creation_info` only fires on first creation; this guard handles edge cases where the directory was created with different perms by a previous deploy or by a manual operator action. No change to the SIGTERM handling — the existing `exec` already lets SIGTERM reach sendmail directly.
- No change to [`docker/shared/entrypoint.sh`](../../docker/shared/entrypoint.sh) — verified it does not touch the queue.

### Sendmail `.mc` change

In [`out-sendmail.mc`](../../docker/templates/out-sendmail.mc), add:

```m4
define(`confMIN_QUEUE_AGE', `5m')dnl
```

This sets the minimum age before a queued message is eligible for a fresh delivery attempt by *any* queue runner. With multiple `smtp-out` tasks each running `-q15m`, a freshly-enqueued message would otherwise be eligible for a second attempt within seconds of acceptance. 5 minutes is conservative — enough to avoid thundering-herd retries against a remote MTA that just deferred us, short enough that a real outbound after a transient blip still goes out promptly.

`confTO_QUEUERETURN=4d` is left as-is. The bounce horizon was already chosen for "messages can sit deferred for days"; persistent queue doesn't change the rationale, it just makes the existing 4-day window meaningful where today it's effectively capped at the deploy cadence.

## Concurrency and locking

Sendmail's queue-runner concurrency is per-`qf` file: each candidate message is locked via `fcntl(F_SETLK)` on its control file before delivery is attempted. EFS supports NFSv4 byte-range locks, so this works across mount points and across hosts. The "shared NFS mqueue" pattern was the canonical way to scale sendmail before everyone moved to commercial MTAs, and it's documented in the sendmail `op.me` operations guide.

Three failure modes worth naming explicitly, with how each is handled:

1. **Two tasks pick the same message simultaneously.** Both `fcntl` the `qf`, one wins, the loser logs `lost lock` and moves on. No double-delivery. Standard.
2. **A task dies mid-delivery, holding a lock.** NFSv4 advisory locks are released by EFS when the client connection drops (NFS `RELEASE_LOCKOWNER`). A surviving task picks up the orphaned `qf` on its next scan. Worst case: the message is delivered twice if the dying task already handed the message off to the remote MTA but didn't get to delete the `qf`. This is identical to the failure mode of any persistent queue under host loss, and is bounded by the same idempotency the recipient MTA already needs (Message-ID-based dedup).
3. **A task dies mid-write, leaving a partial `tf` or `df`.** Sendmail's startup queue scan ignores files that don't pair (`qf` without `df`, or `tf` not yet renamed to `qf`); they age out via the temp-file cleanup or get picked up on the next full scan. No corruption.

## Migration sequence

One PR per phase, in order. Each phase is independently apply-able and each phase's rollback is the previous phase.

1. **Verify the smmsp gid.** A throwaway PR (or just a CI run on a docs-only branch) that prints `getent group smmsp` from inside the smtp-out container. Bake the resulting gid into the access-point Terraform in step 2. No infra change.
2. **Add the EFS access point.** Terraform-only PR: new `aws_efs_access_point.smtp_queue` resource and module output. No mount yet, no behavioural change. The access point creates `/smtp-queue` on the filesystem with the correct ownership.
3. **Mount the queue and bump timeouts.** PR with three coordinated changes:
   - `task-definitions.tf` — add the `volume` and `mountPoints` blocks, add `stopTimeout = 120`.
   - `smtp-out/supervisord.conf` — `stopwaitsecs=15 → 110`.
   - `shared/sendmail-wrapper.sh` — defensive `chown`/`chmod`.

   On apply, ECS rolls the smtp-out service. Each new task mounts the (empty) shared queue. The first deploy effectively starts the persistent-queue era with a clean slate; any messages already queued in the *previous* task's ephemeral `mqueue` are lost in this one transition — same failure mode as any deploy today, no worse.
4. **Add `confMIN_QUEUE_AGE`.** Single-line `.mc` change, triggers a docker rebuild and a fresh service rollout. With the persistent queue already in place, the `MIN_QUEUE_AGE` is the last bit of multi-runner coordination tuning.
5. **Soak.** One week minimum at the new posture, watching for: `mailq` depth on each task agreeing (proves shared mount works), no `lost lock` storms in CloudWatch Logs (proves `fcntl` semantics work over EFS), no perms errors on `qf` writes (proves the access-point creation_info matched smmsp).

### Per-environment ordering

`dev` end-to-end through phase 5, then `stage`, then `prod`. The access point is cheap to create in advance across all three (phase 2 can fan out), but the mount/timeout change (phase 3) is the breakable one and should bake on dev for at least a few deploys before promotion.

### Rollback

| Step | Rollback |
| --- | --- |
| Verify gid (1) | None needed — read-only. |
| Access point (2) | Delete the `aws_efs_access_point` resource. The `/smtp-queue` directory remains on the filesystem; harmless. |
| Mount + timeouts (3) | Revert the task-definition, supervisord, and wrapper changes. ECS rolls back to ephemeral queue. Any messages in the persistent queue at rollback time are stranded — manually copy them out of the EFS mount on a one-off basis if necessary, or let the new ephemeral queue accept replacements as users retry sending. |
| `MIN_QUEUE_AGE` (4) | Single-line revert. No state implication. |

## Operational considerations

- **CloudWatch alarms.** Add metrics for: EFS `PercentIOLimit` on the mailstore filesystem (alarm at >70% sustained — IMAP and the queue share IOPS budget); `BurstCreditBalance` (alarm at <50%); supervisord-reported `sendmail` exit codes !=0 in the smtp-out logs. The third is the primary signal that the queue dir's perms got desynced.
- **Throughput posture.** Start with bursting throughput (the current default — see [`efs/main.tf:5`](../../terraform/infra/modules/efs/main.tf:5), which omits `throughput_mode`). Move to provisioned only if the alarm above fires under steady load. The queue's metadata churn is negligible compared to IMAP read traffic on the same filesystem.
- **Backup churn.** AWS Backup's scheduled backups of the mailstore EFS will incidentally include the queue. This is fine — queue files are tiny and ephemeral, and a restore of a queue snapshot would simply hand sendmail a slightly stale set of `qf` files to retry, which is already its job. Worth adding a one-line note in [`docs/operations.md`](../operations.md) about not panicking if a restored EFS shows queue contents.
- **Poison messages.** With persistence, a message that triggers a sendmail crash will follow the service across deploys instead of being washed away. Mitigation: the existing `confTO_QUEUERETURN=4d` already bounces undeliverable messages; for crash-loop scenarios the operator's tool is `mailq` + `mailq -qI<id> -d` to drop the offender. Document in the operations runbook.
- **Cross-mount isolation.** IMAP mounts the same EFS at `root_directory = "/"`; an `imap` container has filesystem-level visibility into `/smtp-queue` and vice versa via paths. This is the same trust boundary as today (both run our code on our infrastructure), but worth flagging if we ever introduce third-party tenant code into either tier.
- **mqueue-client.** Left ephemeral on purpose. If a future change adds `submit.cf` to the smtp-out image (e.g. for local cron-originated mail), revisit whether `/var/spool/mqueue-client` also needs persistence. It probably doesn't — local-origin mail is far more recoverable than user-submitted mail.

## Acceptance

- A `smtp-out` task forced to terminate (ECS `StopTask`) while a `mailq` shows queued retries, with a sibling task running, results in zero lost messages — the sibling delivers them on its next queue run. Verify on dev by submitting a message addressed to a domain that returns `421 try again later` (or a test domain we control), then `StopTask` on the originating instance.
- A clean redeploy (image push → service update) of `smtp-out` with a non-empty queue results in zero lost messages, and the `confTO_QUEUERETURN=4d` window is the only thing that bounds eventual delivery.
- `mailq` from any task shows the same queue contents (modulo race with active queue runs).
- No `lost lock` errors in CloudWatch Logs during a 24-hour soak with normal traffic.
- EFS `PercentIOLimit` and `BurstCreditBalance` alarms remain green through a full week of normal traffic plus a redeploy.

## Open questions

- **Verified smmsp gid on AL2023.** Step 1 of the migration sequence resolves this; recording here as a reminder that the `25` in this plan is provisional.
- **IAM auth on the EFS mount.** Left disabled here for parity with the IMAP mount. Worth a follow-up posture pass to enable it on both mounts in one PR, once the queue work has soaked.
- **`confMIN_QUEUE_AGE` value.** 5m is a defensible default; if greylist-heavy domains bunch up in the queue, we may want to raise it to 15m to align with the queue-run cadence. Tune during soak.
- **Queue-runner separation.** Sendmail supports running the listener and the queue runner as separate processes (`-bd` + `-q15m` rather than `-bD -q15m` in one). Splitting them would let us scale queue runners independently of submission capacity, but adds supervisord complexity. Defer until queue depth justifies it.

## Out of scope for 0.9.0

- Replacing sendmail with a queue-aware MTA (Postfix, OpenSMTPD).
- Hardening `cabal-efs-sg` to per-tier ingress rules.
- Migrating IMAP onto an access point.
- Per-tenant queue isolation.

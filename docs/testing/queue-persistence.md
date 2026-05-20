# Queue-persistence test runbook

Validates that a deferred message in `smtp-out`'s sendmail queue survives an ECS task replacement, handing off cleanly to whichever sibling task next scans the shared EFS-backed queue. Uses the SMTP sinkhole test fixture ([docs/0.9.x/sinkhole-test-harness-plan.md](../0.9.x/sinkhole-test-harness-plan.md)) to produce a deterministic 4xx response on demand.

This runbook also serves as the acceptance procedure for phase 3 of [docs/0.9.x/smtp-out-queue-persistence-plan.md](../0.9.x/smtp-out-queue-persistence-plan.md).

## When to run

- After a change to the smtp-out task definition, the shared EFS queue access point, or the supervisord stop-wait sequence.
- After bumping `confMIN_QUEUE_AGE` or the queue-runner cadence.
- Before promoting a queue-persistence-adjacent change from `stage` to `main`.
- One-off when investigating reports of lost outbound mail.

## Prerequisites

- The sinkhole tier must be enabled in the target environment: `TF_VAR_SINKHOLE=true` in the GitHub environment variables and a successful `infra.yml` run that applied the resulting plan. Refused in prod by the variable's validation block and the task definition's precondition; run this only in `stage` (preferred) or `dev`.
- An AWS CLI profile with permission to call `ssm:PutParameter`, `ecs:DescribeServices`, `ecs:UpdateService`, `ecs:ExecuteCommand`, and `logs:FilterLogEvents` in the target account.
- A test mailbox to originate the send from. Any Cabalmail user account works; create a fresh address (e.g. `qp-test-2026-05@<your-subdomain>`) so the test traffic is easy to filter in logs.

## Test sequence

The sinkhole's response shape is controlled by `/cabal/sinkhole_mode`. The listener re-reads this parameter on each new connection (30 s cache), so flips take effect on the next sendmail retry attempt without any task replacement.

### 1. Park the sinkhole in `defer` mode

```sh
aws ssm put-parameter \
  --name /cabal/sinkhole_mode \
  --value defer \
  --overwrite
```

This is the default value Terraform writes; the explicit `put-parameter` makes the test idempotent across rerunning the sequence.

### 2. Send a test message to `sinkhole.test`

From the test mailbox, send to any local-part on `sinkhole.test` (RFC 2606 reserved TLD; never resolves on the public internet):

```sh
# Via the admin app: compose to anything@sinkhole.test and Send.
# Or via curl, with a fresh Cognito access token:
curl -sS -X POST "https://api.<control-domain>/send" \
  -H "Authorization: Bearer ${COGNITO_ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "from": "qp-test-2026-05@<your-subdomain>",
    "to":   ["nobody-1@sinkhole.test"],
    "subject": "queue-persistence test",
    "body": "test"
  }'
```

The send API returns 200 immediately; the actual SMTP exchange happens inside `smtp-out` over the next few seconds.

### 3. Confirm the message is queued on every smtp-out task

List smtp-out tasks and inspect `mailq` on each:

```sh
TASKS=$(aws ecs list-tasks \
  --cluster cabal-mail \
  --service-name cabal-smtp-out \
  --query 'taskArns[]' --output text)

for arn in $TASKS; do
  echo "=== ${arn} ==="
  aws ecs execute-command \
    --cluster cabal-mail \
    --task "$arn" \
    --container smtp-out \
    --command 'mailq' \
    --interactive
done
```

Every task should show the message in queue with a `Deferred: 421-4.3.2 Service temporarily unavailable` status. The shared `/var/spool/mqueue` mount on EFS means every running task sees the same queue.

### 4. Force-replace one smtp-out task

Pick one task ARN from step 3 and stop it:

```sh
aws ecs stop-task \
  --cluster cabal-mail \
  --task <task-arn> \
  --reason 'queue-persistence test - validating handoff'
```

ECS will start a replacement task automatically. Watch `aws ecs describe-services --cluster cabal-mail --services cabal-smtp-out` until the service settles back to its steady-state count.

### 5. Confirm queue survives the replacement

Re-run the `mailq` loop from step 3 against the *new* task list. The message must still appear, with the same queue id, on every running task including the replacement.

If the message has disappeared from any task, the test has failed. Capture `mailq -Ac` and the CloudWatch `/ecs/cabal-smtp-out` logs from the affected window and file an issue; do not promote the change.

### 6. Flip the sinkhole to `accept`

```sh
aws ssm put-parameter \
  --name /cabal/sinkhole_mode \
  --value accept \
  --overwrite
```

### 7. Wait for the next retry

Sendmail retries on its own cadence (defaults: ~30 minutes for the first retry after a 4xx, growing thereafter). To trigger an immediate retry instead of waiting:

```sh
aws ecs execute-command \
  --cluster cabal-mail \
  --task <any-smtp-out-task-arn> \
  --container smtp-out \
  --command 'sendmail -q -v' \
  --interactive
```

`sendmail -q` walks the entire queue; with the sinkhole now in `accept` mode, the message gets a `250 OK` and is removed.

### 8. Verify delivery and queue drain

Re-run the `mailq` loop one more time. Every task should report `Mail queue is empty`. Cross-check the `/ecs/cabal-smtp-out` log group for the `to=<nobody-1@sinkhole.test>` line with `stat=Sent`. If the sinkhole is in `accept-log` mode (not used here, but useful for envelope-capture tests), the `/ecs/cabal-sinkhole` log group will also have an `accepted: {...}` entry.

## Cleanup

Park the sinkhole back in `defer` so an accidental subsequent send to `sinkhole.test` does not silently succeed:

```sh
aws ssm put-parameter \
  --name /cabal/sinkhole_mode \
  --value defer \
  --overwrite
```

If you are done with the harness for an extended period, the sinkhole tier is cheap to leave running (~50 MB memory, no inbound traffic when nothing is testing). Disabling it requires a Terraform-side change (`TF_VAR_SINKHOLE=false` in the environment variables and a fresh `infra.yml` run); see the rollback table in the harness plan.

## Cleanup safety net

A leaked `sinkhole.test` recipient in production code would silently queue indefinitely against a destination that does not resolve. Nothing in the Cabalmail codebase generates such addresses today, but as a guardrail watch the `smtp-out` log group for `sinkhole.test` in queue-add events; surface anything found via the standard alert path.

## Test data hygiene

The deferred message sits in `/var/spool/mqueue` until either step 6/7 delivers it or the sendmail retry budget expires (default 5 days, then bounce). If you abandon the test mid-sequence, run step 6 + 7 to drain, or delete the queue entry by id with `sendmail -qI<id> -d8.43` on one of the tasks.

## Related

- [docs/0.9.x/sinkhole-test-harness-plan.md](../0.9.x/sinkhole-test-harness-plan.md) - design of the SMTP sinkhole fixture.
- [docs/0.9.x/smtp-out-queue-persistence-plan.md](../0.9.x/smtp-out-queue-persistence-plan.md) - the underlying queue-persistence work.
- [docs/operations/runbooks/sendmail-deferred-spike.md](../operations/runbooks/sendmail-deferred-spike.md) - alert runbook for *real* deferred-mail spikes; the sinkhole test should not trip this alarm if your test send volume stays below the threshold.

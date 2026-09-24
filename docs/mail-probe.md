# Post-deploy mail probe

After `app.yml` rolls a core mail tier (`imap`, `smtp-in`, `smtp-out`) or deploys the API Lambdas, its `mail-probe` job proves that mail still flows through the environment, end to end, from the outside. The ECS rollout wait only proves the new container passes its health check; the probe proves the mail path behind it.

## What it does

The probe ([`.github/scripts/mail-probe.py`](../.github/scripts/mail-probe.py)) signs in to Cognito as a dedicated `ci-probe` user and sends that user two messages with unique subjects:

| Leg | Path | Passes when |
| --- | --- | --- |
| `api` | `PUT /send` -> send Lambda -> smtp-out (submission auth, DKIM signing) -> mailertable -> imap | The message is in INBOX with a `DKIM-Signature` header |
| `mx` | MX lookup -> plain SMTP to port 25 -> NLB -> smtp-in (milters, relay) -> imap | The message is in INBOX with the `Authentication-Results` header smtp-in's milters stamp |

Both legs are needed. smtp-out routes hosted domains straight to the IMAP container over Cloud Map, bypassing the load balancer's port 25 listener, so an API-only probe never touches smtp-in. The `mx` leg is what the rest of the internet does when it delivers to us.

Reception is verified through the API (`/list_messages`, `/list_envelopes`, `/fetch_message`), which also exercises the Lambda-side master-user IMAP login. On success the probe moves both messages, and the Sent copy that `/send` queues, to Trash and purges them, so the mailbox stays empty. On failure it leaves them in place for diagnosis; the next run sweeps them before it starts.

The job runs on GitHub-hosted runners, which can open outbound port 25. It reads no repository secrets: the control domain comes from the environment's `TF_VAR_CONTROL_DOMAIN` variable, everything else from the public `config.json` and the probe user's own address list, and the password from SSM through the deploy role.

## What it proves, and what it does not

It proves: Cognito password auth; API Gateway and the send, list and fetch Lambdas; smtp-out's submission auth against Cognito and its DKIM signing; the MX record, the NLB port 25 listener and its target group; smtp-in's access map, milter chain and relay to imap; imap's local delivery, procmail and Dovecot; and the master-user login the Lambdas use.

It does not prove: outbound delivery to other providers (use the [sinkhole](./operations.md#test-fixtures-and-pre-promotion-verification) or a real external mailbox); the public IMAPS (993) and submission (587/465) listeners, which no first-party client uses; SPF, DKIM or DMARC *verdicts* (the `mx` leg is unauthenticated by design, so its verdicts are `none` or `fail`; only the header's presence is asserted); push notifications; or certificate validity on smtp-in (a failed STARTTLS verification is a warning, not a failure, because opportunistic-TLS MTAs carry on the same way).

## When it runs

`mail-probe` waits for `docker` and `lambda-api` and runs when either deployed something relevant: a core tier in `changed_tiers`, or any API function. It is skipped when only monitoring tiers rolled, when a deploy job failed (that run is already red), or when the environment gate was not approved. A normal run takes one to three minutes; the job times out at twenty.

It is a detector, not a gate. By the time it runs the roll has happened, and the only automatic rollback is the imap deployment circuit breaker, which acts on task health. A red probe turns the `app.yml` run red, which the [release dashboard](./releasing.md) surfaces before promotion.

## Reading a failure

Log lines are prefixed `[mail-probe]`, and the failing assertion is also raised as an `error` annotation on the run. In the order they can occur:

- **config.json or Cognito errors**: the front door or user pool is unhealthy, or the `ci-probe` user is missing or disabled. Check `aws cognito-idp admin-get-user --user-pool-id <pool> --username ci-probe`.
- **`could not read SSM parameter /cabal/ci-probe/password`**: Terraform has not applied `ci_probe_user.tf` in this account yet, or the deploy role's live policy lacks `ssm:GetParameter`.
- **`GET /list_messages -> 500` on the first run after provisioning**: imap has not restarted since the `ci-probe` user was created, so Dovecot has no such user. Roll the imap tier (see [Provisioning](#provisioning)) and re-run.
- **`mx leg: ... did not accept the message` with a `550` for the probe address, on the first run after provisioning**: smtp-in's access map predates the address. It refreshes on the next address change in the environment or the next smtp-in roll.
- **`PUT /send` retries, then gives up**: the send Lambda or smtp-out is unhealthy. `/send` is SMTP-first and does not wait on IMAP, so an IMAP maintenance window does not explain this.
- **`mx leg: ... did not accept the message`**: smtp-in rejected or timed out. A `550` or `553` means the access map no longer lists the probe address (check the `[generate-config]` lines in the smtp-in task log); a timeout means the NLB listener or its target is unhealthy.
- **`not delivered within the reception budget: api`**: smtp-out accepted the message but imap never got it. Look at the smtp-out queue ([mail queues](./mail-queues.md)) and imap's sendmail and procmail logs.
- **`not delivered within the reception budget: mx`**: smtp-in accepted the message but did not relay it. Same places, smtp-in side.
- **`arrived without a DKIM-Signature header`**: smtp-out is delivering unsigned. Check OpenDKIM in the smtp-out task log and the DKIM key in SSM.
- **`arrived without an Authentication-Results header`**: smtp-in's milters are not stamping. Check opendkim and opendmarc in the smtp-in task log.

Leftover `[ci-probe] ...` messages in the probe mailbox after a failure are expected and harmless.

## Running it by hand

From a shell with AWS credentials for the target account:

```
./.github/scripts/mail-probe.py --control-domain <control domain>
```

Useful switches: `--legs api` or `--legs mx` to isolate one path, `--keep` to leave the messages in the mailbox for inspection, `--mx-host` to bypass the MX lookup, and `--label` to name the run. To run as any other user, set `MAIL_PROBE_PASSWORD` (and, for a TOTP-enrolled user, `MAIL_PROBE_TOTP_SECRET` or `--totp-secret-param`) and pass `--username` and `--address`. The sweep only ever touches messages whose subject starts with `[ci-probe]`, so a shared account is safe.

The pure helpers (TOTP, MX parsing, subject matching, address selection) are covered by `scripts/tests/test_mail_probe.py`.

## Provisioning

[`terraform/infra/modules/app/ci_probe_user.tf`](../terraform/infra/modules/app/ci_probe_user.tf) creates, per environment, the `ci-probe` Cognito user (osid 9997), its address `ci-probe@mail-admin.<first mail domain>`, and the `/cabal/ci-probe/password` SSM SecureString. Nothing is seeded by hand. The pool's pre-sign-up invite gate fires for admin-created users too; `check_invite` exempts that trigger source, because an `AdminCreateUser` caller is already IAM-authorized, and that is what lets Terraform create the user while the invitation code is set. The deploy role's reference policy in [AWS setup](./aws.md) already grants `ssm:GetParameter`; an account whose live policy predates that grant fails the probe at the SSM read with a clear message.

The containers pick the user up on their own schedule. `sync-users.sh` runs only when a container starts, so the imap tier has to roll once after the apply before the `api` leg can pass; smtp-in adds the address to its access map on its next reconfigure event (any address change in the environment) or its next roll. A probe that runs before then fails with one of the two provisioning signatures listed under [Reading a failure](#reading-a-failure). The quickest way to finish provisioning is a `workflow_dispatch` of `app.yml` with `force_tiers` set to `imap,smtp-in`, which also runs the probe.

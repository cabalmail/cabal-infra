# Monitoring & Alerting

The 0.7.0 release adds an optional monitoring stack on top of the existing mail infrastructure. Phase 1 provides black-box uptime monitoring plus a push-notification alerting path that bypasses the Cabalmail email system. Phase 2 adds heartbeat monitoring for scheduled jobs (certbot, weekly Terraform, AWS Backup, DMARC ingestion, ECS reconfigure loop, Cognito user-sync). See [monitoring-plan.md](./0.7.0/monitoring-plan.md) for the multi-phase roadmap and design rationale; this page is the operator's runbook for enabling the stack and completing first-boot configuration.

The stack is disabled by default. When enabled it deploys:

- **Uptime Kuma** — a small, self-hosted status-page / probe runner. Reachable at `https://uptime.<control-domain>/` behind Cognito login.
- **Self-hosted ntfy** — open-source push-notification server. Reachable at `https://ntfy.<control-domain>/` with token auth enforced by the app (not the ALB).
- **`alert_sink` Lambda** — a webhook sink fronted by a Lambda Function URL. Callers authenticate with a shared secret. `critical` severity fans out to Pushover (priority 1) and ntfy (priority 5); `warning` goes to ntfy (priority 3); `info` is dropped.
- **Self-hosted Healthchecks** (Phase 2) — a [healthchecks.io](https://healthchecks.io) instance for "did this scheduled job ping recently?" heartbeats. Reachable at `https://heartbeat.<control-domain>/` behind Cognito.
- **`backup_heartbeat` Lambda** (Phase 2) — invoked by an EventBridge rule on AWS Backup `JOB_COMPLETED` events; pings the corresponding Healthchecks check.

## 1. Create your Pushover account and application

Pushover is the "wake someone up" channel — priority-1 pushes bypass Do Not Disturb on iOS and Android. It is paid: **$5 one-time per mobile platform** you intend to receive alerts on, after a 30-day trial.

1. Go to <https://pushover.net/signup> and create an account. Verify your email.
2. Install the Pushover app from the App Store / Play Store and log in. After login you'll see your **user key** on the app's home screen and on <https://pushover.net>.
3. On the Pushover site, open **Your Applications → Create an Application/API Token**. Name it `cabalmail-alerts`, type `Application`. Accept the terms. You'll get an **API Token/Key**.
4. Save both values somewhere temporarily (password manager). You'll put them into SSM in step 5.

## 2. Enable the flag per environment

The monitoring stack is gated by `var.monitoring`. Set it to `true` only in the environments where you want it on (prod always; stage/dev only while actively testing).

In your GitHub repository settings, go to **Settings → Environments → _environment_ → Variables** and add:

| Variable            | Example value | Notes                                                               |
| ------------------- | ------------- | ------------------------------------------------------------------- |
| `TF_VAR_MONITORING` | `true`        | Set to `true` in `prod`; leave as `false` (or unset) elsewhere.     |

## 3. Apply Terraform

Kick off the "Build and Deploy Terraform Infrastructure" workflow (same process as in [setup.md §Provisioning](./setup.md)). The apply will create:

- `cabal-uptime-kuma` and `cabal-ntfy` ECR repositories (always, regardless of the flag).
- SSM `SecureString` parameters: `/cabal/alert_sink_secret` (auto-generated random), `/cabal/pushover_user_key`, `/cabal/pushover_app_token`, `/cabal/ntfy_publisher_token` (all with `ignore_changes` so manual values stick).
- `alert_sink` Lambda with a Function URL.
- Uptime Kuma and ntfy ECS services, both EFS-backed.
- Public ALB with:
  - Default rule → Kuma, fronted by Cognito.
  - Host-header rule on `ntfy.<control-domain>` → ntfy (no ALB auth).
- Route 53 records `uptime.<control-domain>` and `ntfy.<control-domain>`.

Note the Terraform outputs — you will need `alert_sink_function_url` and `ntfy_service_name` below.

## 4. Seed the Pushover SSM parameters

```
aws ssm put-parameter --name /cabal/pushover_user_key  --type SecureString --overwrite --value '<user-key-from-step-1>'
aws ssm put-parameter --name /cabal/pushover_app_token --type SecureString --overwrite --value '<app-token-from-step-1>'
```

Terraform won't touch these on subsequent applies (`ignore_changes = [value]`).

## 5. Bootstrap the ntfy admin user and publisher token

ntfy ships with `NTFY_AUTH_DEFAULT_ACCESS=deny-all`; nobody can read or write until you create an admin. Do it once via ECS Exec.

1. Find the ntfy task ARN:
   ```
   CLUSTER=<cluster-name>
   TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name cabal-ntfy --query 'taskArns[0]' --output text)
   ```
2. Open a shell in the container:
   ```
   aws ecs execute-command --cluster "$CLUSTER" --task "$TASK" --container ntfy --interactive --command "/bin/sh"
   ```
3. Inside the container, create the admin user. You'll be prompted for a password — **store it in your password manager**, you'll need it on the phone.
   ```
   ntfy user add --role=admin admin
   ```
4. Generate a bearer token for the Lambda:
   ```
   ntfy token add admin
   ```
   Copy the `tk_...` token it prints.
5. Exit the container. Store the token in SSM:
   ```
   aws ssm put-parameter --name /cabal/ntfy_publisher_token --type SecureString --overwrite --value 'tk_...'
   ```

The Lambda caches secrets at cold start, so the next push after the secret-set triggers a re-fetch automatically.

## 6. Subscribe your phone to ntfy

1. Install the ntfy app from the App Store / Play Store.
2. In the app, **Settings → Users** (or similar), add a user for `https://ntfy.<control-domain>` with username `admin` and the password from step 5.
3. Tap **Subscribe to topic** → server `https://ntfy.<control-domain>`, topic `alerts`. The app shows 0 messages until the first alert fires.

## 7. First-boot configuration in Uptime Kuma

Uptime Kuma ships without any admin user; the first person to hit the UI creates one.

1. Open `https://uptime.<control-domain>/` in a browser. You will be redirected to the Cognito hosted UI to sign in.
2. After the Cognito handshake you land on Kuma's setup page. Create the admin account. **Store the password in your password manager** — Kuma does not use Cognito for its own identity; it has a separate local user.

## 8. Wire the Kuma webhook notification provider

In Kuma, add a new Notification provider:

- **Type**: Webhook
- **Post URL**: value of the `alert_sink_function_url` Terraform output (the Lambda Function URL, e.g. `https://abc123.lambda-url.us-west-1.on.aws/`).
- **Request body**: *JSON (content-type: application/json)*
- **Custom headers**:
  ```
  X-Alert-Secret: <paste from /cabal/alert_sink_secret>
  ```
  Retrieve the secret with:
  ```
  aws ssm get-parameter --name /cabal/alert_sink_secret --with-decryption --query Parameter.Value --output text
  ```
- **Body template**:
  ```json
  {
    "summary": "{{ msg }}",
    "severity": "{% if heartbeatJSON.status == 0 %}critical{% else %}info{% endif %}",
    "source": "kuma/{{ monitorJSON.name }}"
  }
  ```

  Kuma uses Liquid templating — `{{ ... }}` for interpolation, `{% if %}…{% endif %}` for conditionals. Handlebars-style `{{#if}}` will fail with a TokenizationError.

Click **Test** — you should receive a Pushover push **and** a ntfy notification within 30 seconds. If either is missing, check the `alert_sink` CloudWatch log group at `/cabal/lambda/alert_sink` for per-transport errors.

## 9. Create the Phase 1 monitor set

In the Kuma dashboard, add one monitor for each row below. Attach the webhook notification to every monitor.

| Monitor                        | Type        | Target                                     | Interval | Retries |
| ------------------------------ | ----------- | ------------------------------------------ | -------- | ------- |
| IMAP TLS handshake             | TCP port    | `imap.<control-domain>:993`                | 60 s     | 2       |
| SMTP relay (STARTTLS)          | TCP port    | `smtp-in.<control-domain>:25`              | 60 s     | 2       |
| Submission (STARTTLS)          | TCP port    | `smtp-out.<control-domain>:587`            | 60 s     | 2       |
| Submission (implicit TLS)      | TCP port    | `smtp-out.<control-domain>:465`            | 60 s     | 2       |
| Admin app                      | HTTP(s)     | `https://admin.<control-domain>/`          | 120 s    | 2       |
| API round-trip (`/list`)       | HTTP(s)     | `https://admin.<control-domain>/prod/list` | 5 min    | 2       |
| ntfy server health             | HTTP(s)     | `https://ntfy.<control-domain>/v1/health`  | 120 s    | 2       |
| Control-domain cert            | Keyword     | `https://admin.<control-domain>/`, keyword: any. Enable **Certificate expiration notification**: 21 / 7 / 1 days. | 4 h | 2 |

The `/list` probe needs a valid Cognito JWT. In Phase 1, seed it manually: sign in to the admin app, copy your `id_token` out of DevTools, and paste it as `Authorization: Bearer <token>` in the monitor's headers. Rotate it monthly. (Phase 4 adds a longer-lived monitor identity.)

## 10. Acceptance checklist

- [ ] `https://uptime.<control-domain>/` is unreachable without a Cognito session.
- [ ] `https://ntfy.<control-domain>/alerts` returns `401` without a bearer token.
- [ ] Temporarily blocking port 993 in the dev account (security group or `fail2ban` rule) produces a Pushover push **and** a ntfy push within ~2 minutes.
- [ ] Unblocking it produces a recovery push.
- [ ] Every Phase 1 monitor shows green in the Kuma dashboard.

## Secret rotation

To rotate the webhook shared secret:

1. Generate a new value: `openssl rand -base64 36 | tr -d '='`.
2. Put it into SSM: `aws ssm put-parameter --name /cabal/alert_sink_secret --type SecureString --overwrite --value '<new-value>'`.
3. Update the `X-Alert-Secret` header on every Kuma webhook provider.
4. Trigger a test notification from Kuma to confirm.

To rotate the ntfy publisher token: run `ntfy token del <old-token>` and `ntfy token add admin` inside the container, then update `/cabal/ntfy_publisher_token`.

To rotate the Pushover app token: create a new application on pushover.net, update `/cabal/pushover_app_token`, delete the old application.

The Terraform `ignore_changes = [value]` lifecycle on each SSM parameter means subsequent `terraform apply` runs will not revert your rotated value.

## Disabling the stack

Set `TF_VAR_MONITORING=false` in the GitHub environment and re-run Terraform. The module is gated with `count = var.monitoring ? 1 : 0`, so the ECS services, ALB, Lambda, and SSM parameters are destroyed cleanly. The `cabal-uptime-kuma`, `cabal-ntfy`, and `cabal-healthchecks` ECR repositories and the Cognito user pool domain persist (they are cheap and not flag-gated).

**Note on EFS state:** destroying the stack leaves the `/uptime-kuma`, `/ntfy`, and `/healthchecks` directories on the shared EFS. Re-enabling monitoring later will pick up the existing SQLite databases and ntfy user/auth state, preserving your configuration. Remove the directories manually from any running mail-tier container if you want a clean start.

---

# Phase 2: Heartbeat monitoring

Phase 2 adds Healthchecks for the scheduled jobs that Phase 1 cannot see (cron-style runs, EventBridge schedules, the ECS reconfigure loop). It is enabled by the same `TF_VAR_MONITORING=true` flag — there is no separate switch. Once Phase 1 is up, follow the steps below to bring Phase 2 online.

## 11. First-boot configuration in Healthchecks

`https://heartbeat.<control-domain>/` sits behind Cognito. The Cabalmail Cognito user pool is the front door; Healthchecks itself uses its own local accounts (Cognito gates whether you can _reach_ the UI, Healthchecks gates whether you can _change_ checks).

1. Open `https://heartbeat.<control-domain>/` in a browser. Cognito challenges you. Sign in.
2. On the Healthchecks landing page, click **Sign Up** (Healthchecks ships with `REGISTRATION_OPEN=True` so the first apply lets you create the operator account). Use a real email address (Healthchecks sends confirmation links and password-reset emails — see step 13 if you want email notifications wired up).
3. Confirm the email if your inbox is reachable. If not, you can mark the user verified directly in the SQLite store via ECS Exec:
   ```
   aws ecs execute-command --cluster <cluster> \
     --task $(aws ecs list-tasks --cluster <cluster> --service-name cabal-healthchecks --query 'taskArns[0]' --output text) \
     --container healthchecks --interactive --command /bin/sh
   # inside the container:
   ./manage.py shell -c "from accounts.models import Profile; p=Profile.objects.first(); p.user.is_active=True; p.user.save()"
   ```
4. Once registration is complete, lock the door: set `REGISTRATION_OPEN=False` in [healthchecks.tf](../terraform/infra/modules/monitoring/healthchecks.tf) and apply. (You can also flip it via ECS Exec by editing the env var on the running task definition for a quick fix; the next Terraform run will reconcile.)

## 12. Create one check per scheduled job

In the Healthchecks dashboard, click **Add Check** for each entry below. The **schedule** column tells Healthchecks what cadence to expect; tune the **grace** column if it produces false alarms.

| Check name             | Schedule type / value          | Grace | Notes                                                          |
| ---------------------- | ------------------------------ | ----- | -------------------------------------------------------------- |
| `certbot-renewal`      | Simple, every 60 days          | 24 h  | Lambda runs every 60 days via EventBridge Scheduler.           |
| `terraform-weekly`     | Simple, every 7 days           | 24 h  | GitHub Actions only pings on a successful apply.               |
| `aws-backup`           | Simple, every 1 day            | 6 h   | EventBridge `JOB_COMPLETED` events feed `backup_heartbeat`.    |
| `dmarc-ingest`         | Simple, every 6 hours          | 2 h   | DMARC scheduler runs every 6 h.                                |
| `ecs-reconfigure`      | Simple, every 30 minutes       | 30 m  | Pings on each successful regenerate; fallback fires every 15 m.|
| `cognito-user-sync`    | Simple, every 30 days          | 7 d   | Fires only on user signup; very loose grace by design.         |

For each check, copy the **ping URL** (e.g. `https://heartbeat.<control-domain>/ping/abcd1234-...`) and paste it into the matching SSM parameter:

```
aws ssm put-parameter --name /cabal/healthcheck_ping_certbot_renewal     --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_terraform_weekly    --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_aws_backup          --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_dmarc_ingest        --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_ecs_reconfigure     --type SecureString --overwrite --value '<url>'
aws ssm put-parameter --name /cabal/healthcheck_ping_cognito_user_sync   --type SecureString --overwrite --value '<url>'
```

Lambdas cache the URL at cold start, so the next invocation after the secret-set picks it up automatically. The mail-tier containers receive the URL via ECS task-definition `secrets` and need a deployment cycle (`aws ecs update-service --force-new-deployment`) to pick up changes.

## 13. Wire Healthchecks alerts back to `alert_sink`

A missed heartbeat is only useful if it becomes a push notification. In Healthchecks, **Integrations → Add Integration → Webhook**:

- **URL for "down" events** — the same `alert_sink_function_url` from Phase 1.
- **HTTP Method** — `POST`.
- **HTTP Headers**:
  ```
  Content-Type: application/json
  X-Alert-Secret: <value of /cabal/alert_sink_secret>
  ```
- **Request Body**:
  ```json
  {"summary": "Missed heartbeat: $NAME", "severity": "critical", "source": "healthchecks/$NAME"}
  ```
- **URL for "up" events** — same URL.
- **Body for "up" events**:
  ```json
  {"summary": "Recovered: $NAME", "severity": "warning", "source": "healthchecks/$NAME"}
  ```

Then assign the integration to every check from step 12.

## 14. Acceptance checklist for Phase 2

- [ ] `https://heartbeat.<control-domain>/` is unreachable without a Cognito session.
- [ ] Every check from step 12 shows green in the Healthchecks dashboard within one full schedule cycle (i.e. the certbot check stays "new" until either you trigger the Lambda manually or wait 60 days; the others should turn green within 24 hours).
- [ ] Disabling the certbot Lambda's EventBridge schedule in dev (or temporarily setting its ping SSM parameter to `placeholder-`) and waiting past the grace window produces a Pushover push and a ntfy push citing `healthchecks/certbot-renewal`.
- [ ] Manually triggering the certbot Lambda (`aws lambda invoke --function-name cabal-certbot-renewal /tmp/out.json`) restores the check to green within one cold-start.
- [ ] Triggering `aws backup start-backup-job` (or waiting for the daily run) advances the `aws-backup` check.

## Disabling individual heartbeats

To silence one heartbeat without disabling the entire monitoring stack: pause the corresponding check in the Healthchecks UI, or set its SSM parameter back to a value that does not start with `http` (e.g. `aws ssm put-parameter --overwrite --type SecureString --name /cabal/healthcheck_ping_dmarc_ingest --value 'paused'`). Consumer code skips the ping when the value is not an HTTP(S) URL, and Healthchecks stops expecting pings while the check is paused.

## Phase 2 troubleshooting

- **Healthchecks task crash-looping with permission errors on `/data`.** Same shape as the Kuma `chown` issue from Phase 1 lesson 2 in [monitoring-plan.md §6](./0.7.0/monitoring-plan.md). The EFS access point under `/healthchecks` is owned by `1000:1000` with `0755`; any upstream entrypoint that tries to `chown` it will fail. If a future Healthchecks release adds a chown shim, follow the Kuma fix: override `entryPoint` and `user` in [healthchecks.tf](../terraform/infra/modules/monitoring/healthchecks.tf) so the container starts directly as `1000:1000` and skips the shim. The current `v3.10` image's entrypoint runs `manage.py migrate` then `uwsgi` — no chown — so no override is needed yet.
- **Healthchecks dashboard shows `heartbeat.<control-domain>` but Cognito redirects loop.** The ALB SG already has `alb_https_out` from Phase 1 (Cognito token exchange). If the loop is on first signup specifically, it's the `REGISTRATION_OPEN=True → False` flip in the task definition: confirm `True` until the operator account is created, then commit a flip to `False` and apply.
- **Heartbeat misfires immediately after enabling monitoring.** Each consumer caches the SSM ping URL at cold start (Lambdas) or task start (containers). After populating a placeholder, force a refresh: `aws lambda invoke --function-name cabal-certbot-renewal /tmp/out.json` for Lambdas; `aws ecs update-service --cluster <cluster> --service cabal-imap --force-new-deployment` (and the smtp tiers) for the reconfigure heartbeat.
- **`backup_heartbeat` Lambda silent.** Confirm `var.backup = true` in the environment — without the AWS Backup plan, no `Backup Job State Change` events fire and the EventBridge rule has nothing to invoke. The Lambda existing without the backup plan is harmless but useless.

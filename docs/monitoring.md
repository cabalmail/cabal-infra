# Monitoring & Alerting

The 0.7.0 release adds an optional monitoring stack on top of the existing mail infrastructure. Black-box uptime monitoring, heartbeat monitoring for scheduled jobs, a Prometheus / Alertmanager / Grafana metrics stack, log-derived alerts via CloudWatch metric filters, and a runbook for every alert that can fire. All of it routes through a push-notification path (Pushover + self-hosted ntfy) that bypasses Cabalmail's own email tier so the operator stays reachable during a mail outage.

See [docs/0.7.0/monitoring-plan.md](./0.7.0/monitoring-plan.md) for the design rationale. This document is the operator's runbook for enabling the stack and completing first-boot configuration. All steps are required unless explicitly marked optional.

The stack is disabled by default. When enabled it deploys:

- **Uptime Kuma** -- self-hosted status-page / probe runner. Reachable at `https://uptime.<control-domain>/` behind Cognito login.
- **Self-hosted ntfy** -- open-source push-notification server. Reachable at `https://ntfy.<control-domain>/` with token auth enforced by ntfy itself (the ALB does not gate this hostname).
- **`alert_sink` Lambda** -- webhook sink fronted by a Lambda Function URL. Callers authenticate with a shared secret. `critical` severity fans out to Pushover (priority 1) and ntfy (priority 5); `warning` goes to ntfy (priority 3); `info` is dropped.
- **Self-hosted Healthchecks** -- a [healthchecks.io](https://healthchecks.io) instance for "did this scheduled job ping recently?" heartbeats. Reachable at `https://heartbeat.<control-domain>/` behind Cognito.
- **`backup_heartbeat` Lambda** -- invoked by an EventBridge rule on AWS Backup `JOB_COMPLETED` events; pings the corresponding Healthchecks check.
- **`cabal-healthchecks-iac` Lambda** -- reconciles Healthchecks check definitions from [`lambda/api/healthchecks_iac/config.py`](../lambda/api/healthchecks_iac/config.py) and populates the `/cabal/healthcheck_ping_*` SSM parameters. Auto-invokes when the config changes.
- **Prometheus, Alertmanager, Grafana** -- metrics stack. Grafana is reachable at `https://metrics.<control-domain>/` behind Cognito. Prometheus and Alertmanager have no public surface; reach via Grafana's data-source proxy or `aws ecs execute-command`.
- **`cloudwatch_exporter`, `blackbox_exporter`, `node_exporter`** -- Prometheus exporters. The first two are single-task ECS services; node_exporter is a DAEMON service (one task per cluster instance).
- **CloudWatch metric filters** on the mail-tier log groups, emitting to a `Cabalmail/Logs` namespace. cloudwatch_exporter scrapes these and Prometheus alerts on the rates (sendmail deferred, sendmail bounced, IMAP auth failures).

## 1. Create your Pushover account and application

Pushover is the "wake someone up" channel -- priority-1 pushes bypass Do Not Disturb on iOS and Android. It is paid: **$5 one-time per mobile platform** you intend to receive alerts on, after a 30-day trial.

1. Go to <https://pushover.net/signup> and create an account. Verify your email.
2. Install the Pushover app from the App Store / Play Store and log in. After login you'll see your **user key** on the app's home screen and on <https://pushover.net>.
3. On the Pushover site, open **Your Applications -> Create an Application/API Token**. Name it `cabalmail-alerts`, type `Application`. Accept the terms. You'll get an **API Token/Key**.
4. Save both values somewhere temporarily (password manager). You'll put them into SSM in step 5.

## 2. Enable the flag per environment

The monitoring stack is gated by `var.monitoring`. Set it to `true` only in the environments where you want it on (prod always; stage/dev only while actively testing).

In your GitHub repository settings, go to **Settings -> Environments -> _environment_ -> Variables** and add:

| Variable                                  | Example value | Notes                                                                                                                    |
| ----------------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `TF_VAR_MONITORING`                       | `true`        | Gates the whole stack. Set to `true` in `prod`; leave as `false` (or unset) elsewhere.                                   |
| `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN`   | `false`       | Controls whether the Healthchecks signup form accepts new accounts. Defaults to `false` (closed) when unset; flip to `true` for the bootstrap signup in step 11, then back to `false`. Has no effect when `TF_VAR_MONITORING=false`. |

## 3. Build container images (first time only)

Prometheus, Alertmanager, Grafana, the three Prometheus exporters, Uptime Kuma, ntfy, and Healthchecks all ship as ECR images built by `.github/workflows/docker.yml`. The first time you toggle `TF_VAR_MONITORING=true` after this release lands, run the **Build and Push Container Images** workflow first -- this populates the new ECR repositories with `sha-<first-8>` tags. Then run the Terraform workflow.

If you flip `TF_VAR_MONITORING` to `true` without the images present, ECS keeps the new services in `pending` state until the images appear; nothing else breaks, but no progress is made until the build runs.

## 4. Apply Terraform

Kick off the **Build and Deploy Terraform Infrastructure** workflow (same process as in [setup.md](./setup.md)). The apply creates:

- ECR repositories: `cabal-uptime-kuma`, `cabal-ntfy`, `cabal-healthchecks`, `cabal-prometheus`, `cabal-alertmanager`, `cabal-grafana`, `cabal-cloudwatch-exporter`, `cabal-blackbox-exporter`, `cabal-node-exporter` (always, regardless of the flag, so the Docker workflow can push unconditionally).
- SSM `SecureString` parameters with `ignore_changes = [value]` so out-of-band rotation sticks: `/cabal/alert_sink_secret` (auto-generated), `/cabal/pushover_user_key`, `/cabal/pushover_app_token`, `/cabal/ntfy_publisher_token`, `/cabal/healthchecks_api_key`, six `/cabal/healthcheck_ping_*` placeholders, `/cabal/grafana_admin_password` (auto-generated), and `/cabal/healthchecks_secret_key` (auto-generated Django secret).
- The `alert_sink` Lambda with a Function URL.
- ECS services for ntfy, Uptime Kuma, Healthchecks, Prometheus, Alertmanager, Grafana, cloudwatch_exporter, blackbox_exporter, and the node_exporter DAEMON.
- A public ALB:
  - Default listener action -> Kuma, Cognito-authenticated.
  - Host-header rules on `ntfy.<control-domain>` (no ALB auth; ntfy enforces token auth), `heartbeat.<control-domain>` (Cognito), `metrics.<control-domain>` (Cognito).
- Cloud Map private DNS namespace `cabal-monitoring.cabal.internal` with services for prometheus, alertmanager, grafana, cloudwatch-exporter, blackbox-exporter, node-exporter, and healthchecks (used by the IaC Lambda).
- The `backup_heartbeat` Lambda + EventBridge rule.
- The `cabal-healthchecks-iac` Lambda in private subnets.
- Three CloudWatch metric filters per mail tier emitting to `Cabalmail/Logs`.
- Route 53 records `uptime.<control-domain>`, `ntfy.<control-domain>`, `heartbeat.<control-domain>`, `metrics.<control-domain>` (in both the public zone and the VPC private zone, since the private zone shadows the public zone for the control domain).

Note the Terraform output `alert_sink_function_url` -- you will need it in step 9 and step 14.

## 5. Seed the Pushover SSM parameters

```
aws ssm put-parameter --name /cabal/pushover_user_key  --type SecureString --overwrite --value '<user-key-from-step-1>'
aws ssm put-parameter --name /cabal/pushover_app_token --type SecureString --overwrite --value '<app-token-from-step-1>'
```

Terraform won't touch these on subsequent applies (`ignore_changes = [value]`).

## 6. Bootstrap the ntfy admin user and publisher token

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
3. Inside the container, create the admin user. You'll be prompted for a password -- **store it in your password manager**, you'll need it on the phone.
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

The `alert_sink` Lambda caches secrets at cold start, so the next push after the secret-set triggers a re-fetch automatically.

## 7. Subscribe your phone to ntfy

1. Install the ntfy app from the App Store / Play Store.
2. In the app, **Settings -> Users** (or similar), add a user for `https://ntfy.<control-domain>` with username `admin` and the password from step 6.
3. Tap **Subscribe to topic** -> server `https://ntfy.<control-domain>`, topic `alerts`. The app shows 0 messages until the first alert fires.

## 8. First-boot configuration in Uptime Kuma

Uptime Kuma ships without any admin user; the first person to hit the UI creates one.

1. Open `https://uptime.<control-domain>/` in a browser. You will be redirected to the Cognito hosted UI to sign in.
2. After the Cognito handshake you land on Kuma's setup page. Create the admin account. **Store the password in your password manager** -- Kuma does not use Cognito for its own identity; it has a separate local user.

## 9. Wire the Kuma webhook notification provider

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
  {% raw %}
  ```json
  {
    "summary": "{{ msg }}",
    "severity": "{% if heartbeatJSON.status == 0 %}critical{% else %}info{% endif %}",
    "source": "kuma/{{ monitorJSON.name }}"
  }
  ```
  {% endraw %}

  Kuma uses Liquid templating -- {% raw %}`{{ ... }}`{% endraw %} for interpolation, {% raw %}`{% if %}...{% endif %}`{% endraw %} for conditionals. Handlebars-style {% raw %}`{{#if}}`{% endraw %} fails with a TokenizationError.

Click **Test** -- you should receive a Pushover push **and** a ntfy notification within 30 seconds. If either is missing, check the `alert_sink` CloudWatch log group at `/cabal/lambda/alert_sink` for per-transport errors.

## 10. Create the uptime monitor set

In the Kuma dashboard, add one monitor for each row below. Attach the webhook notification to every monitor. The monitor names must match the keys in the `_RUNBOOK_MAP` in [`lambda/api/alert_sink/function.py`](../lambda/api/alert_sink/function.py); renaming a monitor without updating the map silently drops the runbook link from its push.

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

The `/list` probe needs a valid Cognito JWT. Seed it manually: sign in to the admin app, copy your `id_token` out of DevTools, and paste it as `Authorization: Bearer <token>` in the monitor's headers. Rotate it monthly.

## 11. First-boot configuration in Healthchecks

`https://heartbeat.<control-domain>/` sits behind Cognito. The Cabalmail Cognito user pool is the front door; Healthchecks itself uses its own local accounts (Cognito gates whether you can _reach_ the UI, Healthchecks gates whether you can _change_ checks).

The Healthchecks task is wired to deliver mail through the IMAP tier's local-delivery sendmail (`EMAIL_HOST=imap.cabal.internal`, port 25, no TLS, no auth) -- see [healthchecks.tf](../terraform/infra/modules/monitoring/healthchecks.tf). This means magic-link signup and password reset work natively, **as long as you sign up with a Cabalmail-hosted address whose mailbox you can read**. Mail destined for non-Cabalmail addresses (gmail, etc.) won't deliver from this Healthchecks instance -- it can only relay inbound to itself.

1. Open the signup form: in your GitHub environment for this stack, set `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN=true` and re-run the Terraform workflow. The default is `false` (closed); flipping to `true` lets the Healthchecks `Sign Up` form accept new accounts.
2. Pick a Cabalmail address you own to use as the operator login (e.g. `admin@<one-of-your-mail-domains>`). It needs to be a real address in `cabal-addresses`; if it isn't, IMAP's sendmail will TEMPFAIL the magic-link delivery.
3. Open `https://heartbeat.<control-domain>/` in a browser. Cognito challenges you. Sign in.
4. On the Healthchecks landing page, click **Sign Up** and enter the address from step 2. Healthchecks emails a magic link; the link arrives in your Cabalmail inbox within seconds. Click it to set a password.
5. Lock the door: set `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN=false` (or just delete the variable -- `false` is the default) and re-run Terraform.

**Fallback if mail delivery doesn't work** (e.g. you want to bootstrap before adding a Cabalmail address, or the IMAP tier is down): create a superuser via ECS Exec and log in with the password form:

```
aws ecs execute-command --cluster <cluster> \
  --task $(aws ecs list-tasks --cluster <cluster> --service-name cabal-healthchecks --query 'taskArns[0]' --output text) \
  --container healthchecks --interactive --command /bin/sh
# inside the container:
cd /opt/healthchecks
./manage.py shell -c "from django.contrib.auth.models import User; User.objects.filter(email='you@example.com').delete()"
./manage.py createsuperuser
```

Then log in at `https://heartbeat.<control-domain>/accounts/login/` using the password field (next to the magic-link button).

## 12. Bootstrap the Healthchecks API key

The `cabal-healthchecks-iac` Lambda needs a v3 API key to manage checks programmatically. The API has no endpoint to create keys, so this is a one-time manual step.

1. In Healthchecks, click the gear icon (top-right) -> **Project Settings** -> **API Access**. Create a key labelled `cabal-healthchecks-iac` with **read-write** permissions. Copy the value.
2. Seed it into SSM:
   ```sh
   aws ssm put-parameter --name /cabal/healthchecks_api_key --type SecureString --overwrite --value '<key-from-step-1>'
   ```

The auto-invocation of the IaC Lambda at apply time saw the placeholder and returned `status: skipped` -- no error, but no checks were created either. Step 13 forces the reconcile now that the key is real.

## 13. Reconcile checks via the healthchecks_iac Lambda

```sh
aws lambda invoke --function-name cabal-healthchecks-iac /tmp/out.json && cat /tmp/out.json
```

Expected output: `{"status":"ok","reconciled":6,"failed":0,"extras":[],"checks":[...]}`. The Lambda upserts six checks defined in [`lambda/api/healthchecks_iac/config.py`](../lambda/api/healthchecks_iac/config.py) and writes each ping URL into the matching `/cabal/healthcheck_ping_*` SSM parameter:

| Check name             | Schedule          | Grace | Pinged by                                                       |
| ---------------------- | ----------------- | ----- | --------------------------------------------------------------- |
| `certbot-renewal`      | Every 60 days     | 24 h  | `cabal-certbot-renewal` Lambda (EventBridge Scheduler).         |
| `aws-backup`           | Every 1 day       | 6 h   | `cabal-backup-heartbeat` Lambda (EventBridge `JOB_COMPLETED`).  |
| `dmarc-ingest`         | Every 6 hours     | 2 h   | `cabal-process-dmarc` Lambda.                                   |
| `ecs-reconfigure`      | Every 30 minutes  | 30 m  | `reconfigure.sh` loop in mail-tier containers.                  |
| `cognito-user-sync`    | Every 30 days     | 7 d   | `assign_osid` post-confirmation Lambda. Fires only on user signup. |
| `quarterly-review`     | Every 90 days     | 14 d  | Manual operator ping (see step 15).                             |

Consumers cache the ping URL at cold start (Lambdas) or task start (mail-tier containers). After step 13 populates the SSM values, force the consumers to pick them up:

```sh
# Mail-tier reconfigure loop:
for tier in imap smtp-in smtp-out; do
  aws ecs update-service --cluster <cluster> --service cabal-$tier --force-new-deployment
done
# Lambdas pick up new values on next cold start. Force one to verify:
aws lambda invoke --function-name cabal-certbot-renewal /tmp/out.json
```

## 14. Wire Healthchecks alerts back to alert_sink

The IaC Lambda creates checks but cannot create notification channels (the v3 API doesn't expose channel CRUD). Create one webhook integration manually and assign it to every check.

In Healthchecks, **Integrations -> Add Integration -> Webhook**:

- **URL for "down" events**: the `alert_sink_function_url` from Terraform output.
- **HTTP Method**: `POST`.
- **HTTP Headers**:
  ```
  Content-Type: application/json
  X-Alert-Secret: <value of /cabal/alert_sink_secret>
  ```
- **Request Body**:
  ```json
  {"summary": "Missed heartbeat: $NAME", "severity": "critical", "source": "healthchecks/$NAME"}
  ```
- **URL for "up" events**: same URL.
- **Body for "up" events**:
  ```json
  {"summary": "Recovered: $NAME", "severity": "warning", "source": "healthchecks/$NAME"}
  ```

Then **assign the integration to every check** from step 13 (toggle the check's notification list to include the new integration). The `source` strings -- `healthchecks/certbot-renewal`, `healthchecks/aws-backup`, etc. -- must match the keys in the `_RUNBOOK_MAP` in `alert_sink/function.py`; renaming a check without updating the map drops the runbook link.

## 15. Bootstrap the quarterly-review check

The `quarterly-review` check has no automation pinging it on a schedule -- the operator pings it manually after walking through the quarterly review (see "Quarterly monitoring review" below). Ping it once now so it starts green, with a 90-day clock:

```sh
PING_URL=$(aws ssm get-parameter --name /cabal/healthcheck_ping_quarterly_review --with-decryption --query Parameter.Value --output text)
curl -fsS "$PING_URL"
```

## 16. Set the Grafana admin password (optional)

Terraform auto-generates a random Grafana admin password on first apply (`/cabal/grafana_admin_password`, `ignore_changes` so subsequent applies don't rotate it). Read it with:

```
aws ssm get-parameter --name /cabal/grafana_admin_password --with-decryption --query Parameter.Value --output text
```

Or set your own:

```
aws ssm put-parameter --name /cabal/grafana_admin_password --type SecureString --overwrite --value '<your-password>'
```

Grafana picks up the value at task start (`GF_SECURITY_ADMIN_PASSWORD`); a `force-new-deployment` rolls in any change.

## 17. First-boot configuration in Grafana

1. Open `https://metrics.<control-domain>/`. Cognito challenges; sign in.
2. You arrive as an anonymous Viewer. Navigate to **Cabalmail -> Dashboards** in the side menu -- four provisioned dashboards (`Mail Tiers`, `AWS Services`, `API Gateway & Lambda`, `Frontend`) are already there. Initial charts will be empty for ~5 min until cloudwatch_exporter has scraped.
3. To make changes -- add a panel, edit a datasource, install a plugin -- sign in to the local admin account at `/login`. The username is `admin`; the password is the SSM value from step 16.
4. The Prometheus datasource is provisioned read-only at `http://prometheus.cabal-monitoring.cabal.internal:9090`. To verify, **Connections -> Data sources -> Prometheus -> Test**.

## 18. Verify Prometheus scrape targets

Prometheus has no public UI by default. To inspect scrape state:

```
CLUSTER=<cluster-name>
TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name cabal-prometheus --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster "$CLUSTER" --task "$TASK" --container prometheus --interactive --command "/bin/sh"
# inside the container:
wget -qO- http://localhost:9090/api/v1/targets | head
```

Every target listed in `prometheus.yml` should be `health: up`. Targets to expect: 1x prometheus self-scrape, 1x alertmanager, 1x cloudwatch-exporter, 4x blackbox probes (HTTP + 3x TCP), and 1+x node-exporter (one per cluster EC2 instance).

## 19. Acceptance checklist

- [ ] `https://uptime.<control-domain>/` is unreachable without a Cognito session.
- [ ] `https://ntfy.<control-domain>/alerts` returns `401` without a bearer token.
- [ ] `https://heartbeat.<control-domain>/` is unreachable without a Cognito session.
- [ ] `https://metrics.<control-domain>/` is unreachable without a Cognito session.
- [ ] Temporarily blocking port 993 on the dev account (security group) produces a Pushover push **and** a ntfy push within ~2 minutes. Unblocking it produces a recovery push.
- [ ] Every uptime monitor from step 10 shows green in the Kuma dashboard.
- [ ] `aws lambda invoke --function-name cabal-healthchecks-iac /tmp/out.json` returns `status: ok` with `reconciled: 6`.
- [ ] All six `/cabal/healthcheck_ping_*` SSM parameters hold real `https://heartbeat.<control-domain>/ping/...` URLs (not placeholders).
- [ ] Every check from step 13 shows green within one full schedule cycle.
- [ ] The `quarterly-review` check shows green after step 15.
- [ ] Disabling the certbot Lambda's EventBridge schedule on dev (or temporarily setting `/cabal/healthcheck_ping_certbot_renewal` to a non-`http` value) and waiting past the 24 h grace produces a Pushover + ntfy push citing `healthchecks/certbot-renewal`. Tappable runbook link opens [heartbeat-certbot-renewal.md](./operations/runbooks/heartbeat-certbot-renewal.md).
- [ ] Grafana shows all four provisioned dashboards under the **Cabalmail** folder.
- [ ] `cloudwatch_exporter`, `node_exporter`, and `blackbox_exporter` targets are all `up` in Prometheus.
- [ ] `aws logs describe-metric-filters --log-group-name /ecs/cabal-imap` lists `cabal-sendmail-deferred-imap`, `cabal-sendmail-bounced-imap`, and `cabal-imap-auth-failures`.
- [ ] Synthetic alert: tighten one warning rule (e.g. `EFSBurstCreditsLow` to `< 100e9`) in [docker/prometheus/rules/alerts.yml](../docker/prometheus/rules/alerts.yml), rebuild + redeploy, and confirm the Alertmanager -> alert_sink chain produces a ntfy push within ~5 min, with a tappable runbook link.

---

## Runbook framework

Every alert that can fire a push notification has a runbook in [docs/operations/runbooks/](./operations/runbooks/). Each runbook follows the same shape: what the alert means, who/what is impacted, the first three things to check, and how to escalate. See [the runbook README](./operations/runbooks/README.md) for the full index.

How the runbook URL reaches your phone:

- **Prometheus / Alertmanager**: each rule in [docker/prometheus/rules/alerts.yml](../docker/prometheus/rules/alerts.yml) carries a `runbook_url` annotation. Alertmanager forwards it as part of its native webhook body; the `alert_sink` Lambda's translator surfaces it (`_translate_alertmanager`) and attaches it to outbound pushes.
- **Kuma & Healthchecks**: their webhook bodies don't carry a per-monitor runbook URL natively. The `alert_sink` Lambda has a static `_RUNBOOK_MAP` keyed by `source` (e.g. `kuma/IMAP TLS handshake`, `healthchecks/certbot-renewal`). When you add or rename a Kuma monitor or a Healthchecks check, update the keys in [`lambda/api/alert_sink/function.py`](../lambda/api/alert_sink/function.py) to match, or the push will arrive without a runbook link.

When a push includes a runbook URL, you'll see:

- **Pushover**: a "Runbook" tap-action link in the notification, below the body.
- **ntfy**: the notification body itself becomes tappable (`Click` header), opening the runbook in the phone's browser.

The map and the runbook files are version-controlled together; PRs that change one without the other should fail review.

## Tabletop exercises

Run after each meaningful monitoring change, and again at every quarterly review. If the expected push doesn't arrive, fix the broken link before treating the tabletop as passing.

| Scenario | How to simulate | Expected page | Expected runbook |
| --- | --- | --- | --- |
| Mail queue backup (deferred) | ECS-Exec into the `smtp-out` task; inject 12 fake `stat=Deferred` log lines via `logger -t sm-mta 'XXX: stat=Deferred'` in <1 minute, then wait. | `SendmailDeferredSpike` (warning ntfy) within ~17 min (10 min window + 15 min `for`) | [sendmail-deferred-spike.md](./operations/runbooks/sendmail-deferred-spike.md) |
| IMAP cert expiring (control-domain) | In dev: re-issue a short-lived cert and wait, or temporarily replace the listener cert with a deliberately near-expiry one. Don't do this in prod. | `BlackboxTLSCertExpiringSoon` (warning ntfy) and Kuma's "Control-domain cert" 21-day notification | [cert-expiring.md](./operations/runbooks/cert-expiring.md) |
| Certbot Lambda silently disabled | Disable the EventBridge schedule on `cabal-certbot-renewal` in dev; wait past the 24 h grace | `healthchecks/certbot-renewal` missed -> critical ntfy + Pushover | [heartbeat-certbot-renewal.md](./operations/runbooks/heartbeat-certbot-renewal.md) |
| Healthchecks IaC drift | Add a check by hand in the Healthchecks UI without adding it to `config.py`. Re-invoke `cabal-healthchecks-iac`. | Lambda log line `WARNING: extras in Healthchecks not in config.py: [...]`. No alert fires (drift is logged, not paged). | (no runbook -- drift is operator-cleaned) |

## Quarterly monitoring review

The `quarterly-review` Healthchecks check pages the operator if 90+ days pass without a manual ping. The check is **not** automated. Nothing pings it on a schedule. The operator pings it after walking through the checklist in [heartbeat-quarterly-review.md](./operations/runbooks/heartbeat-quarterly-review.md), which covers:

1. Confirm dashboards still load. Open Grafana, walk through Mail Tiers / AWS Services / API Gateway / Frontend. Anything blank that should have data?
2. Review silences in Alertmanager. Are any silences indefinite that should expire?
3. Confirm the on-call number is still correct. Verify the Pushover / ntfy mobile apps still receive a test push.
4. Review the noisiest and longest-silent alerts. Tighten or drop accordingly. Goal: zero false pages in a typical week.
5. Walk at least one tabletop scenario from above.

When you've finished:

```sh
PING_URL=$(aws ssm get-parameter --name /cabal/healthcheck_ping_quarterly_review --with-decryption --query Parameter.Value --output text)
curl -fsS "$PING_URL"
```

## What populates when (Grafana panels)

Some Grafana panels are blank for several minutes after the stack starts; some are blank by design.

- **1-2 min: probe panels** (Mail Tiers TCP/TLS, Frontend HTTP probe). Blackbox-driven; Prometheus scrapes blackbox every 30s.
- **3-5 min: AWS-side metrics that always have a value** (EFS BurstCreditBalance / PercentIOLimit, ECS RunningTaskCount, ACM days to expiry). cloudwatch_exporter polls every 60s with a built-in 120s `delay_seconds` lag (CloudWatch metrics aren't immediately consistent), so first datapoint arrives ~3 min after the exporter starts.
- **Empty until something happens (correct behavior)**: DynamoDB ThrottledRequests, Lambda errors / throttles, API Gateway 5xx rate, the new `aws_cabalmail_logs_*` series. These are alert signals; flat-empty in steady state is what you want.
- **Empty unless someone is using the system**: DynamoDB ConsumedRead/Write CU, API Gateway request count, Lambda duration p95. Use the admin app once and these populate within the next minute.
- **Permanently empty with the current config**: CloudFront panels on the Frontend dashboard. CloudFront metrics live exclusively in `us-east-1`, and a single cloudwatch_exporter task scrapes one region. Either enable the AWS/CloudFront block in [docker/cloudwatch-exporter/config.yml](../docker/cloudwatch-exporter/config.yml) and run a second exporter pinned to `us-east-1`, or strip the panels -- Kuma already covers the React app end-to-end, so they're nice-to-have rather than load-bearing.

If a panel is still blank after ~10 min and isn't in one of the categories above, dig in -- start with `wget -qO- http://localhost:9090/api/v1/label/__name__/values` from inside the Prometheus task to confirm whether the metric series even exists.

## Logs: CloudWatch metric filters

Cabalmail stays on CloudWatch Logs rather than self-hosting Loki. Log volume is small enough that CloudWatch's per-GB cost is negligible, and we don't need cross-tier log correlation in real time. Loki would add another stateful ECS service with EFS-backed chunk storage that grows monotonically; the maintenance cost outweighs the benefit until either log volume or cross-tier search frequency becomes painful.

Log-derived metrics ship as **CloudWatch metric filters** defined in [terraform/infra/modules/monitoring/log_metrics.tf](../terraform/infra/modules/monitoring/log_metrics.tf):

| Filter | Log group(s) | Pattern | Metric (in `Cabalmail/Logs`) |
| --- | --- | --- | --- |
| `cabal-sendmail-deferred-{tier}` | `/ecs/cabal-imap`, `/ecs/cabal-smtp-in`, `/ecs/cabal-smtp-out` | `"stat=Deferred"` | `SendmailDeferred` |
| `cabal-sendmail-bounced-{tier}` | same three | `"dsn=5"` | `SendmailBounced` |
| `cabal-imap-auth-failures` | `/ecs/cabal-imap` | `"imap-login" "auth failed"` | `IMAPAuthFailures` |

All metrics emit value=1 per matching log line, default 0. CloudWatch aggregates per-minute. cloudwatch_exporter scrapes the `Sum` statistic and exposes `aws_cabalmail_logs_<metric>_sum` to Prometheus. Three Prometheus rules in the `log-derived` group of [docker/prometheus/rules/alerts.yml](../docker/prometheus/rules/alerts.yml) alert on the rates:

| Alert | Threshold | Severity | Runbook |
| --- | --- | --- | --- |
| `SendmailDeferredSpike` | >10 deferreds/10 min, sustained 15 min | warning | [sendmail-deferred-spike.md](./operations/runbooks/sendmail-deferred-spike.md) |
| `SendmailBouncedSpike` | >15 bounces/30 min, sustained 15 min | critical | [sendmail-bounced-spike.md](./operations/runbooks/sendmail-bounced-spike.md) |
| `IMAPAuthFailureSpike` | >25 auth-fails/5 min, sustained 5 min | warning | [imap-auth-failure-spike.md](./operations/runbooks/imap-auth-failure-spike.md) |

These thresholds are starting points. Expect them to move once we see what real traffic looks like; record the rationale in the alert's GitHub issue per the [tuning discipline](./0.7.0/monitoring-plan.md#tuning-discipline) in the design doc.

**fail2ban metrics are intentionally not part of this set.** `[program:fail2ban]` is currently commented out in every mail-tier `supervisord.conf`. A metric filter today would publish flat-zero forever and mask the disabled state. Add the filter when fail2ban is re-enabled.

**Cognito post-confirmation Lambda errors** are caught by the existing `LambdaErrors` rule (its `function_name` regex is `cabal-.+|assign_osid`, so the post-confirmation Lambda's invocation errors fire it without a separate log filter).

## Adding new heartbeat checks

To add a new Healthchecks check via IaC:

1. Edit [`lambda/api/healthchecks_iac/config.py`](../lambda/api/healthchecks_iac/config.py) -- add an entry with `name`, `kind`, `timeout`, `grace`, `desc`, `tags`, and `ssm_param`.
2. Add a matching SSM parameter to [`monitoring/ssm.tf`](../terraform/infra/modules/monitoring/ssm.tf) `local.heartbeat_jobs` and reference it from the consumer (Lambda env var, ECS secrets, etc.).
3. If the check needs a runbook (most do), add a markdown file under [`docs/operations/runbooks/`](./operations/runbooks/) and update the static `_RUNBOOK_MAP` in [`alert_sink/function.py`](../lambda/api/alert_sink/function.py) so the push includes a tappable link.
4. Open a PR. CI runs `lambda_api_python.yml` (rebuilds the IaC Lambda zip and the alert_sink zip), then `terraform.yml` (applies and re-invokes the IaC Lambda since the source_code_hash changed).
5. Confirm the new check appears in the Healthchecks dashboard. Assign the existing Webhook integration to it (still manual; the v3 API doesn't expose channel CRUD).

## Disabling the stack

Set `TF_VAR_MONITORING=false` in the GitHub environment and re-run Terraform. The module is gated with `count = var.monitoring ? 1 : 0`, so the ECS services, ALB, Lambdas, and SSM parameters are destroyed cleanly. The ECR repositories and the Cognito user pool domain persist (they are cheap and not flag-gated).

**Note on EFS state:** destroying the stack leaves the `/uptime-kuma`, `/ntfy`, `/healthchecks`, `/prometheus`, `/grafana`, and `/alertmanager` directories on the shared EFS. Re-enabling monitoring later will pick up the existing state, preserving Kuma monitors, Healthchecks checks (which the IaC Lambda will reconcile against), and Prometheus retention. Remove the directories manually from any running mail-tier container if you want a clean start.

## Disabling individual heartbeats

To silence one heartbeat without disabling the entire monitoring stack: pause the corresponding check in the Healthchecks UI, or set its SSM parameter back to a value that does not start with `http` (e.g. `aws ssm put-parameter --overwrite --type SecureString --name /cabal/healthcheck_ping_dmarc_ingest --value 'paused'`). Consumer code skips the ping when the value is not an HTTP(S) URL, and Healthchecks stops expecting pings while the check is paused.

The IaC Lambda will not overwrite a pausing value: its update flow only writes ping URLs back to SSM when the Healthchecks API returns one, and pause state in Healthchecks does not change the URL.

## Secret rotation

To rotate the webhook shared secret:

1. Generate a new value: `openssl rand -base64 36 | tr -d '='`.
2. Put it into SSM: `aws ssm put-parameter --name /cabal/alert_sink_secret --type SecureString --overwrite --value '<new-value>'`.
3. Update the `X-Alert-Secret` header on every Kuma webhook provider and the Healthchecks integration headers.
4. Trigger a test notification from Kuma to confirm.

To rotate the ntfy publisher token: run `ntfy token del <old-token>` and `ntfy token add admin` inside the container, then update `/cabal/ntfy_publisher_token`.

To rotate the Pushover app token: create a new application on pushover.net, update `/cabal/pushover_app_token`, delete the old application.

To rotate the Healthchecks API key: in the UI, **Project Settings -> API Access**, revoke the old key and create a new one. Update `/cabal/healthchecks_api_key`. The IaC Lambda picks up the new value on next invocation.

The Terraform `ignore_changes = [value]` lifecycle on each SSM parameter means subsequent `terraform apply` runs will not revert your rotated value.

## Troubleshooting

Notes below are lessons from the actual deploy. Each is also reflected in code; this list is for future readers and re-deployers.

### ALB and Cognito

- **Monitoring ALB needs >=2 AZs.** ALBs require subnets in at least two availability zones. Production has two AZs in `TF_VAR_AVAILABILITY_ZONES`; dev and stage have one each, and the per-AZ `cidrsubnet` math in the VPC module makes adding a second AZ destructive (every subnet is renumbered). The monitoring stack was deployed directly to prod for that reason.
- **ALB SG needs egress to Cognito.** The `authenticate-cognito` action calls Cognito's hosted UI domain to swap the auth code for tokens. Without an HTTPS egress rule on the ALB SG, the call drops and the ALB returns 500 on `/oauth2/idpresponse`. Egress to `0.0.0.0/0:443` is the minimum.
- **Lambda Function URLs need TWO resource-policy statements.** With `authorization_type = NONE`, AWS requires both `lambda:InvokeFunctionUrl` (auth-layer check) and `lambda:InvokeFunction` scoped to URL callers via `lambda:InvokedViaFunctionUrl=true` (execute layer). Missing either returns 403 at the URL gateway. The aws Terraform provider >= **6.28.0** added `invoked_via_function_url = true` on `aws_lambda_permission`; earlier versions can't express this condition declaratively.
- **VPC private hosted zone shadows the public zone for the control domain.** Records that exist only in the public zone don't resolve from inside the VPC. The monitoring module mirrors `admin.`, `uptime.`, `ntfy.`, `heartbeat.`, `metrics.` into the private zone so VPC-internal callers (Kuma probes, the IaC Lambda) can resolve them. Mail-tier hosts (`imap.`, `smtp-in.`, `smtp-out.`) are intentionally not mirrored -- Kuma's TCP probes for those tiers point at the NLB's public DNS name directly.

### EFS access points

- **EFS access points reject `chown`.** Several upstream images (`louislam/uptime-kuma`, `healthchecks/healthchecks`, `grafana/grafana`) chown a data directory at boot or container creation, which EFS access points refuse regardless of caller. Three patterns work around this:
  - Override `entryPoint` and `user` in the task definition so the image starts directly as 1000:1000 without the chown shim (Kuma).
  - Mount EFS at a path that doesn't exist in the image (`/var/local/healthchecks-data` for Healthchecks, `/grafana-data` for Grafana) and override the data-path env var to match. dockerd's copy-up logic doesn't trigger when the target directory doesn't exist in the image.
  - Force `user = "1000:1000"` on the task definition so writes succeed under the access point's translated uid (Healthchecks).
- The same trick will apply to any future upstream image that pre-creates its data directory.

### Cloud Map service discovery

- **Cloud Map service replacement cycle on every `terraform apply`.** AWS deprecated the `failure_threshold` field on `health_check_custom_config` and pins it to `1` server-side regardless. An empty `health_check_custom_config {}` block reads back as drift on every plan and schedules a forced replacement, which fails because the ECS service has live instances registered. Fix in [discovery.tf](../terraform/infra/modules/monitoring/discovery.tf): set `failure_threshold = 1` explicitly and add `lifecycle { ignore_changes = [health_check_custom_config] }`. Without that fix, operators have to manually `aws servicediscovery deregister-instance` after each apply.
- **node_exporter ECS service rejected with `containerName/containerPort must be specified`.** The DAEMON service uses `network_mode = "host"`. With awsvpc, ECS infers the ENI mapping from the task definition; with host or bridge, `service_registries.container_name` and `container_port` must be explicit.
- **node_exporter ECS service rejected with `serviceRegistries value is configured to use a type 'A' DNS record, which is not supported when specifying 'host' or 'bridge' for networkMode`.** A host can run multiple containers on different ports, so ECS can't infer the port from an A-record alone. node_exporter's Cloud Map service registers SRV records instead; the awsvpc-mode services keep type A. Prometheus's scrape config follows: `type: SRV` on the `node` job, `type: A` everywhere else.
- **DAEMON services can't use `capacity_provider_strategy`.** Even an inherited cluster default trips the validator. Use `launch_type = "EC2"` instead -- DAEMON places one task per container instance regardless of which capacity provider supplied it.

### Container images and ECS

- **cloudwatch_exporter container exits immediately with the JVM logging `NumberFormatException`.** The Java cloudwatch_exporter takes its config path positionally (`<port> <config-path>`); the `--config.file=` flag is a Go/Prometheus convention. The flag was being parsed as the listen port and the JVM crashed at startup. The Dockerfile `CMD` passes `/config/config.yml` directly.
- **Grafana shows no provisioned dashboards under the Cabalmail folder.** Two distinct problems can hit at once. First: if the provisioned Prometheus datasource doesn't pin a `uid`, Grafana auto-generates one and the dashboards reference `datasource.uid: "prometheus"` -- the binding silently fails. Second: Grafana 11.x silently rejects provisioned dashboard JSON without a top-level `"id": null` field. Both fixes are in [docker/grafana/provisioning/datasources/prometheus.yml](../docker/grafana/provisioning/datasources/prometheus.yml) and the dashboard JSONs.
- **Grafana "Data source is failing" against Prometheus, but Prometheus is healthy from Exec.** The Grafana SG allows broad egress; the Prometheus SG only allows ingress on 9090 from Grafana's SG (intentional -- Prometheus has no public surface). If the SG rule is missing or stale, `aws ecs update-service --cluster <cluster> --service cabal-grafana --force-new-deployment` rolls the task and re-resolves.

### Healthchecks task

- **Healthchecks task is up and serving but the ALB target stays unhealthy.** Look at the uwsgi log: if `GET /` from the VPC subnet IPs returns HTTP 400 in single-digit ms, Django is rejecting the probe with `DisallowedHost`. ALB target-group health checks can't set a custom Host header -- they send `Host: <target-ip>:<port>`, which fails Django's `ALLOWED_HOSTS` check. The task definition uses `ALLOWED_HOSTS=*` for this reason; hostname enforcement is done at the ALB layer (the listener rule for `heartbeat.<control-domain>` is the only public path to the target group, and the task SG only accepts traffic from the ALB SG).
- **Healthchecks dashboard shows `heartbeat.<control-domain>` but Cognito redirects loop.** If the loop is on first signup specifically, the signup form is closed: set `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN=true` in your GitHub environment and re-run Terraform, complete the signup, then flip the variable back to `false`.

### IaC Lambda and heartbeat consumers

- **Heartbeat misfires immediately after enabling monitoring.** Each consumer caches the SSM ping URL at cold start (Lambdas) or task start (containers). After the IaC Lambda populates the URL, force a refresh: `aws lambda invoke --function-name cabal-certbot-renewal /tmp/out.json` for Lambdas; `aws ecs update-service --cluster <cluster> --service cabal-imap --force-new-deployment` (and the smtp tiers) for the reconfigure heartbeat.
- **`backup_heartbeat` Lambda silent.** Confirm `var.backup = true` in the environment -- without the AWS Backup plan, no `Backup Job State Change` events fire and the EventBridge rule has nothing to invoke. The Lambda existing without the backup plan is harmless but useless.
- **`cabal-healthchecks-iac` returns `status: skipped` on every invocation.** The API key is still placeholder. Repeat step 12.
- **`cabal-healthchecks-iac` returns `status: partial` with an error mentioning DNS.** The Cloud Map A record for Healthchecks isn't registered yet. Confirm the `cabal-healthchecks` ECS service is healthy and registered: `aws servicediscovery list-instances --service-id <id>` should return at least one instance. If it doesn't, force a redeploy of the Healthchecks service.

### alert_sink and Alertmanager

- **Alertmanager's webhook calls fail with `403 Forbidden` from the alert_sink Lambda.** The Lambda accepts both `X-Alert-Secret: <secret>` and `Authorization: Bearer <secret>`. Alertmanager's `http_config.authorization` sets the Bearer header; if the header arrives with leading whitespace or the secret in the wrong env var, the HMAC compare fails. Check the `/cabal/lambda/alert_sink` log group and confirm the SSM secret matches what the entrypoint substituted into `/etc/alertmanager-rendered/alertmanager.yml`.
- **Push arrives without a runbook link.** Three places to check, in order: the Prometheus rule's `runbook_url` annotation (if it's an Alertmanager-routed alert); the source name in the Kuma webhook body or Healthchecks integration body matches a key in `_RUNBOOK_MAP`; the Lambda log shows the resolved runbook URL on each invocation.
- **Kuma webhook templating raises a `TokenizationError`.** Kuma uses Liquid templating ({% raw %}`{% if %}...{% endif %}`{% endraw %}), not Handlebars ({% raw %}`{{#if}}...{{/if}}`{% endraw %}).
- **ntfy admin role doesn't bypass `deny-all` ACLs in older releases -- but in 2.14+ it does.** The mobile-app failures we hit while bootstrapping were instead authentication issues (bcrypt truncates passwords at 72 bytes; non-ASCII or trailing-newline copies fail silently). Operationally: keep the admin password short, ASCII, and pasted carefully.
- **GitHub Actions masks `AWS_REGION` in workflow logs**, including the `alert_sink` Function URL output. The masked URL with literal `***` is unusable; fetch the real URL via `aws lambda get-function-url-config --function-name alert_sink` from a shell with unmasked region.

### Terraform and resource-creation gotchas

- **`aws_security_group` and `aws_security_group_rule` GroupDescription is strict-ASCII** at the EC2 API level. Other AWS resources tolerate Unicode (Cloud Map service descriptions, IAM role descriptions, SSM parameter descriptions all accept em-dashes); SG descriptions don't. `terraform validate` doesn't catch this -- the restriction is enforced at the EC2 API. CI's `tfsec` / `checkov` won't catch it either. Keep all SG-related descriptions ASCII-only.
- **Mail domains have no certs.** Entries in `TF_VAR_MAIL_DOMAINS` are address namespaces only; only the control domain has an ACM cert. Don't add per-mail-domain cert-expiry monitors.
- **`cloudwatch_exporter` IAM scope.** The exporter discovers metrics across all configured namespaces on each scrape, so the task role policy uses wildcard `Resource: "*"` for `cloudwatch:ListMetrics`, `cloudwatch:GetMetricData`, `cloudwatch:GetMetricStatistics`, and `tag:GetResources`. Region-mismatched metric scrapes fail silently -- the exporter doesn't error, it just returns no data; confirm the `AWS_REGION` env var on the task matches the region of the metrics you're scraping.
- **`node_exporter` daemon tasks don't start.** The daemon-strategy service requires the ECS cluster instance role to allow daemon-strategy task placement (the existing `AmazonEC2ContainerServiceforEC2Role` covers this) and for the host's SG to allow inbound TCP 9100 from the Prometheus task SG. The mail-tier `aws_security_group.ecs_instance` already permits all VPC traffic; if you ever scope it down, add an explicit ingress rule for 9100 from the Prometheus SG.

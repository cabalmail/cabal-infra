# Monitoring & Alerting

The 0.7.0 release adds an optional monitoring stack on top of the existing mail infrastructure. Phase 1 provides black-box uptime monitoring plus a push-notification alerting path that bypasses the Cabalmail email system. See [monitoring-plan.md](./0.7.0/monitoring-plan.md) for the multi-phase roadmap and design rationale; this page is the operator's runbook for enabling the stack and completing first-boot configuration.

The stack is disabled by default. When enabled it deploys:

- **Uptime Kuma** — a small, self-hosted status-page / probe runner. Reachable at `https://uptime.<control-domain>/` behind Cognito login.
- **Self-hosted ntfy** — open-source push-notification server. Reachable at `https://ntfy.<control-domain>/` with token auth enforced by the app (not the ALB).
- **`alert_sink` Lambda** — a webhook sink fronted by a Lambda Function URL. Callers authenticate with a shared secret. `critical` severity fans out to Pushover (priority 1) and ntfy (priority 5); `warning` goes to ntfy (priority 3); `info` is dropped.

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

Set `TF_VAR_MONITORING=false` in the GitHub environment and re-run Terraform. The module is gated with `count = var.monitoring ? 1 : 0`, so the ECS services, ALB, Lambda, and SSM parameters are destroyed cleanly. The `cabal-uptime-kuma` and `cabal-ntfy` ECR repositories and the Cognito user pool domain persist (they are cheap and not flag-gated).

**Note on EFS state:** destroying the stack leaves the `/uptime-kuma` and `/ntfy` directories on the shared EFS. Re-enabling monitoring later will pick up the existing SQLite databases and ntfy user/auth state, preserving your configuration. Remove the directories manually from any running mail-tier container if you want a clean start.

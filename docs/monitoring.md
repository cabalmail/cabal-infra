# Monitoring & Alerting

The 0.7.0 release adds an optional monitoring stack on top of the existing mail infrastructure. Phase 1 provides black-box uptime monitoring plus an SMS alerting path. See [monitoring-plan.md](./0.7.0/monitoring-plan.md) for the multi-phase roadmap and design rationale; this page is the operator's runbook for enabling the stack and completing first-boot configuration.

The stack is disabled by default. When enabled it deploys:

- **Uptime Kuma** — a small, self-hosted status-page / probe runner. Reachable at `https://uptime.<control-domain>/` behind Cognito login.
- **`cabal-alerts` SNS topic** — one SMS subscription per on-call phone number.
- **`alert_sms` Lambda** — a webhook sink fronted by a Lambda Function URL. Callers authenticate with a shared secret. `critical` severity goes to SNS/SMS; `warning` goes to SES email; `info` is dropped.

## 1. Enable the flag per environment

The monitoring stack is gated by `var.monitoring`. Set it to `true` only in the environments where you want it on (prod always; stage/dev only while actively testing).

In your GitHub repository settings, go to **Settings → Environments → _environment_ → Variables** and add:

| Variable                      | Example value                 | Notes                                                                 |
| ----------------------------- | ----------------------------- | --------------------------------------------------------------------- |
| `TF_VAR_MONITORING`           | `true`                        | Set to `true` in `prod`; leave as `false` (or unset) elsewhere.       |
| `TF_VAR_ON_CALL_PHONE_NUMBERS` | `[\"+14155551212\"]`         | JSON array of E.164-formatted phone numbers. Escape quotes as shown.  |

Leaving `TF_VAR_ON_CALL_PHONE_NUMBERS` as `[]` deploys the topic without subscribers — useful for dev environments where you want to exercise the pipeline without being paged.

## 2. Apply Terraform

Kick off the "Build and Deploy Terraform Infrastructure" workflow (same process as in [setup.md §Provisioning](./setup.md)). The apply will create:

- `cabal-uptime-kuma` ECR repository (always, regardless of the flag).
- `cabal-alerts` SNS topic with your phone-number subscriptions.
- `/cabal/alert_sms_secret` SSM `SecureString` parameter (random value generated at first apply; ignored on subsequent applies so it can be rotated manually).
- `alert_sms` Lambda with a Function URL.
- Uptime Kuma ECS service on the existing cluster, EFS-backed at access point `/uptime-kuma`.
- Public ALB, Route 53 record `uptime.<control-domain>`, and a Cognito app client for the authenticate-oidc flow.

Note the Terraform outputs — you will need `alert_sms_function_url` and `uptime_url` below.

## 3. Confirm SMS subscriptions

After the apply, each phone number on `TF_VAR_ON_CALL_PHONE_NUMBERS` receives an SNS confirmation SMS. **Each recipient must reply `YES`** (standard SNS protocol) before they will receive alerts. AWS only sends this once, so don't ignore it.

If your AWS account is still in the SMS sandbox, add each number to the sandbox destinations first. See [setup.md §SMS Sandbox](./setup.md#sms-sandbox-required-for-phone-verification).

## 4. First-boot configuration in Uptime Kuma

Uptime Kuma ships without any admin user; the first person to hit the UI creates one.

1. Open `https://uptime.<control-domain>/` in a browser. You will be redirected to the Cognito hosted UI to sign in.
2. After the Cognito handshake you land on Kuma's setup page. Create the admin account. **Store the password in the team password manager** — Kuma does not use Cognito for its own identity; it has a separate local user.
3. Upload a long-lived API key if you plan to manage monitors through the Kuma API later (Phase 4 work).

## 5. Wire the webhook notification provider

In Kuma, add a new Notification provider:

- **Type**: Webhook
- **Post URL**: value of the `alert_sms_function_url` Terraform output (the Lambda Function URL, e.g. `https://abc123.lambda-url.us-west-1.on.aws/`).
- **Request body**: *JSON (content-type: application/json)*
- **Custom headers**:
  ```
  X-Alert-Secret: <paste from /cabal/alert_sms_secret>
  ```
  Retrieve the secret with:
  ```
  aws ssm get-parameter --name /cabal/alert_sms_secret --with-decryption --query Parameter.Value --output text
  ```
- **Body template**:
  ```json
  {
    "summary": "{{msg}}",
    "severity": "{{#if (heartbeatJSON.status == 0)}}critical{{else}}info{{/if}}",
    "source": "kuma/{{monitorJSON.name}}"
  }
  ```

Click **Test** — you should receive an SMS within 30 seconds. If not, check the `alert_sms` CloudWatch log group at `/cabal/lambda/alert_sms` for an auth or publish error.

## 6. Create the Phase 1 monitor set

In the Kuma dashboard, add one monitor for each row below. Attach the webhook notification to every monitor.

| Monitor                        | Type        | Target                                     | Interval | Retries |
| ------------------------------ | ----------- | ------------------------------------------ | -------- | ------- |
| IMAP TLS handshake             | TCP port    | `imap.<control-domain>:993`                | 60 s     | 2       |
| SMTP relay (STARTTLS)          | TCP port    | `smtp-in.<control-domain>:25`              | 60 s     | 2       |
| Submission (STARTTLS)          | TCP port    | `smtp-out.<control-domain>:587`            | 60 s     | 2       |
| Submission (implicit TLS)      | TCP port    | `smtp-out.<control-domain>:465`            | 60 s     | 2       |
| Admin app                      | HTTP(s)     | `https://admin.<control-domain>/`          | 120 s    | 2       |
| API round-trip (`/list`)       | HTTP(s)     | `https://admin.<control-domain>/prod/list` | 5 min    | 2       |
| Control-domain cert            | Keyword     | `https://admin.<control-domain>/`, keyword: any. Enable **Certificate expiration notification**: 21 / 7 / 1 days. | 4 h | 2 |
| Mail-domain certs              | Keyword     | One monitor per entry in `TF_VAR_MAIL_DOMAINS`, same cert settings. | 4 h | 2 |

The `/list` probe needs a valid Cognito JWT. In Phase 1, seed it manually: sign in to the admin app, copy your `id_token` out of DevTools, and paste it as `Authorization: Bearer <token>` in the monitor's headers. Rotate it monthly. (Phase 4 adds a longer-lived monitor identity.)

## 7. Acceptance checklist

- [ ] `https://uptime.<control-domain>/` is unreachable without a Cognito session.
- [ ] Temporarily blocking port 993 in the dev account (security group or `fail2ban` rule) produces an SMS within ~2 minutes.
- [ ] Unblocking it produces a "recovered" SMS.
- [ ] Every Phase 1 monitor shows green in the Kuma dashboard.

## Secret rotation

To rotate the webhook shared secret:

1. Generate a new value: `openssl rand -base64 36 | tr -d '='`.
2. Put it into SSM: `aws ssm put-parameter --name /cabal/alert_sms_secret --type SecureString --overwrite --value '<new-value>'`.
3. Update the `X-Alert-Secret` header on every Kuma webhook provider.
4. Trigger a test notification from Kuma to confirm.

The Terraform `ignore_changes = [value]` lifecycle on the SSM parameter means subsequent `terraform apply` runs will not revert your rotated value.

## Disabling the stack

Set `TF_VAR_MONITORING=false` in the GitHub environment and re-run Terraform. The module is gated with `count = var.monitoring ? 1 : 0`, so the ECS service, ALB, Lambda, SNS topic, and SSM parameter are destroyed cleanly. The `cabal-uptime-kuma` ECR repository and Cognito user pool domain persist (they are cheap and not flag-gated).

**Note on EFS state:** destroying the stack leaves the `/uptime-kuma` directory on the shared EFS. Re-enabling monitoring later will pick up the existing SQLite database, preserving your monitor definitions. Remove the directory manually from any running mail-tier container if you want a clean start.

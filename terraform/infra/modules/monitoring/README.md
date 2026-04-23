# monitoring

Phase 1 of the 0.7.0 monitoring & alerting stack.

Deployed only when `var.monitoring = true` at the root module. See
`docs/0.7.0/monitoring-plan.md` for the overall design and acceptance
criteria.

## What this module creates

- `cabal-alerts` SNS topic with one SMS subscription per entry in
  `on_call_phone_numbers`.
- `/cabal/alert_sms_secret` SSM `SecureString` parameter (shared
  webhook secret). The value is generated at first apply and ignored
  on subsequent applies — rotate manually.
- `alert_sms` Lambda fronted by a Lambda Function URL. Authenticates
  callers with the shared secret in `X-Alert-Secret` and routes by
  severity: `critical` → SNS/SMS, `warning` → SES email, `info`
  → drop.
- Uptime Kuma ECS service (one task, EFS-backed SQLite).
- Public ALB in front of Kuma with a Cognito authenticate-oidc action.
- Route 53 record `uptime.<control-domain>` pointing at the ALB.

## Post-apply manual steps (Phase 1)

1. **On-call numbers:** set `TF_VAR_ON_CALL_PHONE_NUMBERS` in the
   environment variables for each GitHub Actions environment. Each
   recipient must reply `YES` to the first SNS confirmation SMS they
   receive.
2. **Confirm Cognito app client callback:** ALB authenticate-oidc
   reaches Cognito's hosted UI at
   `https://<user_pool_domain>.auth.<region>.amazoncognito.com`. The
   domain is managed in the `user_pool` module.
3. **Configure Uptime Kuma monitors:** open
   `https://uptime.<control-domain>/` (Cognito login), create the
   admin account at first boot, then add the Phase 1 monitor set
   (see `docs/0.7.0/monitoring-plan.md` §Phase 1.3).
4. **Wire the webhook:** in Kuma, add a Webhook notification provider
   with the `alert_sms_function_url` output as the POST URL and a
   custom header `X-Alert-Secret: <value-of-SSM-param>`. Request body
   template:

   ```json
   {
     "summary": "{{msg}}",
     "severity": "{{#if (isUp status)}}info{{else}}critical{{/if}}",
     "source": "kuma/{{monitorJSON.name}}"
   }
   ```

## Acceptance (Phase 1)

- Breaking a health check on dev (e.g. temporarily blocking port 993)
  produces an SMS within ~2 min.
- Kuma's recovery notification sends a "recovered" SMS.
- `https://uptime.<control-domain>/` is reachable only after Cognito
  login.

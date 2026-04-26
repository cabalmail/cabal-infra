# monitoring

Phase 1 of the 0.7.0 monitoring & alerting stack.

Deployed only when `var.monitoring = true` at the root module. See
`docs/0.7.0/monitoring-plan.md` for the overall design and
`docs/monitoring.md` for the operator runbook.

## What this module creates

- SSM `SecureString` parameters:
  - `/cabal/alert_sink_secret` — shared webhook secret (auto-generated
    on first apply; `ignore_changes` so rotation sticks).
  - `/cabal/pushover_user_key` — operator populates after creating a
    Pushover account.
  - `/cabal/pushover_app_token` — operator populates after creating the
    Cabalmail Pushover application.
  - `/cabal/ntfy_publisher_token` — operator populates after
    bootstrapping the ntfy admin user.
- `alert_sink` Lambda fronted by a Lambda Function URL. Authenticates
  callers with the shared secret in `X-Alert-Secret`. Routes by
  severity: `critical` → Pushover priority 1 + ntfy priority 5,
  `warning` → ntfy priority 3, `info` → drop.
- Self-hosted ntfy ECS service (one task, EFS-backed cache + auth DB
  at access point `/ntfy`).
- Uptime Kuma ECS service (one task, EFS-backed SQLite at access point
  `/uptime-kuma`).
- Shared public ALB:
  - Default action → Kuma, fronted by Cognito authenticate-oidc.
  - Host-header rule on `ntfy.<control-domain>` → ntfy (no ALB auth;
    ntfy enforces its own token auth).
- Route 53 records `uptime.<control-domain>` and `ntfy.<control-domain>`.

## Post-apply manual steps (Phase 1)

See `docs/monitoring.md` for detailed steps. Summary:

1. Create a Pushover account + Cabalmail application; put the user key
   and application token into the SSM parameters above.
2. Open an ECS Exec session into the ntfy task; run
   `ntfy user add --role=admin admin` and `ntfy token add admin`; put
   the returned token into `/cabal/ntfy_publisher_token`.
3. Install the Pushover and ntfy mobile apps on the on-call phone; log
   in to ntfy with the admin credentials and subscribe to the `alerts`
   topic.
4. Open `https://uptime.<control-domain>/` (Cognito login), create the
   Kuma admin account, add the Phase 1 monitor set, and wire the
   Webhook notification provider to the `alert_sink_function_url`.

## Acceptance (Phase 1)

- Breaking a health check on dev (e.g. temporarily blocking port 993)
  produces a Pushover **and** ntfy push within ~2 min.
- Kuma's recovery notification sends a follow-up push.
- `https://uptime.<control-domain>/` is reachable only after Cognito login.
- `https://ntfy.<control-domain>/` rejects anonymous requests with 401.

# Runbook: heartbeat missed — `quarterly-review`

Fired by Healthchecks when the `quarterly-review` check has been silent past its 14-day grace beyond the 90-day expected cadence.

## What this means

This is **not** an automation heartbeat — it's a manual prompt. The check has no associated job; it expects you, the operator, to ping it once you've completed the quarterly monitoring review described in [docs/0.7.0/monitoring-plan.md §"Tuning discipline"](../../0.7.0/monitoring-plan.md#tuning-discipline).

A missed ping means it's been more than ~3.5 months since you last:

1. **Confirmed dashboards still load.** Open Grafana, walk through Mail Tiers / AWS Services / API Gateway / Frontend. Anything blank that should have data?
2. **Reviewed silences.** Open Alertmanager (via Grafana data-source proxy). Are any silences indefinite that should expire? Drop ones that have outlived the incident they covered.
3. **Confirmed the on-call number is still correct.** The Pushover and ntfy apps are on a single device today; verify the device still receives test pushes. If you've changed phones, the user key in `/cabal/pushover_user_key` likely needs to be re-seeded.
4. **Reviewed the noisiest and longest-silent alerts.** Tighten or drop accordingly. Goal: zero false pages in a typical week.
5. **Walked at least one tabletop scenario** from [docs/0.7.0/monitoring-plan.md §"Phase 4 §5 acceptance"](../../0.7.0/monitoring-plan.md#5-acceptance-for-phase-4) — simulate a failure mode and confirm the alert path delivers.

## Ping the check

Once you've done the review (it should take 30-60 minutes once a quarter):

```sh
PING_URL=$(aws ssm get-parameter --name /cabal/healthcheck_ping_quarterly_review --with-decryption --query Parameter.Value --output text)
curl -fsS "$PING_URL"
```

That's it. The check goes green for another 90 days.

## Escalation

There is no escalation. If you're getting paged for this and can't dedicate the time, ping the check anyway and open a calendar entry for the next available window. Skipping the review means the monitoring stack drifts away from reality — the cost compounds, but slowly.

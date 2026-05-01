# Runbook: ContainerRestartLoop

Fired by Prometheus rule [`ContainerRestartLoop`](../../../docker/prometheus/rules/alerts.yml) — an ECS service has had `RunningTaskCount < DesiredTaskCount` (averaged over 1 h) for 30 min.

## What this means

An ECS service is failing to keep its desired number of tasks alive. Either every new task crashes shortly after start, or the cluster has no capacity to schedule them.

## Who/what is impacted

The label `service_name` identifies the service. For Cabalmail:

- `cabal-imap`, `cabal-smtp-in`, `cabal-smtp-out`: a mail tier is down or degraded. Probe-failure runbooks ([probe-failure.md](./probe-failure.md)) usually fire alongside.
- `cabal-uptime-kuma`, `cabal-ntfy`: monitoring path itself is degraded. Pages may stop arriving.
- `cabal-healthchecks`: heartbeats stop being recorded — every job will appear "missed" within a schedule cycle.
- `cabal-prometheus`, `cabal-alertmanager`, `cabal-grafana`: metrics-side alerting is offline. Other paths (Kuma, Healthchecks) still page.
- `cabal-cloudwatch-exporter`, `cabal-blackbox-exporter`, `cabal-node-exporter`: scrape targets disappear; downstream Prometheus alerts go quiet (silent failure — bad).

## First three things to check

1. **Is each new task crashing fast, or is the cluster out of capacity?**
   ```sh
   aws ecs describe-services --cluster <cluster> --services <service> \
     --query 'services[0].{running:runningCount,desired:desiredCount,events:events[0:8]}'
   ```
   Events like "unable to place a task" → capacity. "Task stopped: Essential container in task exited" → crash loop.
2. **For a crash loop**: pull the last task's stop reason and logs:
   ```sh
   TASK=$(aws ecs list-tasks --cluster <cluster> --service-name <service> --desired-status STOPPED --query 'taskArns[0]' --output text)
   aws ecs describe-tasks --cluster <cluster> --tasks "$TASK" --query 'tasks[0].containers[0].{reason:reason,exitCode:exitCode}'
   aws logs tail /ecs/<service-log-group> --since 30m --filter-pattern '?ERROR ?Exception ?error ?fatal' | head -50
   ```
3. **For capacity exhaustion**: list cluster instances and check CPU/memory headroom:
   ```sh
   aws ecs describe-container-instances --cluster <cluster> \
     --container-instances $(aws ecs list-container-instances --cluster <cluster> --query 'containerInstanceArns[]' --output text) \
     --query 'containerInstances[].{instance:ec2InstanceId,cpu:remainingResources[?name==`CPU`].integerValue|[0],mem:remainingResources[?name==`MEMORY`].integerValue|[0]}'
   ```
   If every instance has 0 free CPU/memory, the ASG min-size is too low or a bigger instance type is needed.

## Escalation

- **Crash loop on a mail tier after a Docker image push**: roll back. The previous image tag is on the prior `app.yml` workflow run (the `docker` job). The fastest rollback is to call `.github/scripts/deploy-ecs-service.sh <tier> sha-<previous-8>` against the running cluster — the script clones the live task definition, swaps in the older tag, registers a new revision, and rolls the service.
- **EFS access-point related crash** (`failed to chown`): see the Phase 1/2/3 troubleshooting notes in [docs/monitoring.md](../../monitoring.md). A new image that adds a chown-on-start shim recreates the family of bug we've already hit on Kuma, Healthchecks, and Grafana.
- **Capacity exhaustion**: scale the ASG up by one and confirm placement; consider a larger instance type if memory pressure is the issue (the monitoring stack is memory-bound, not CPU-bound).
- This is `critical`. If multiple services are in restart loops simultaneously, suspect the cluster instance role / EFS / network — not the services themselves.

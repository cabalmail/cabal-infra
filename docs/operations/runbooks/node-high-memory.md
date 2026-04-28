# Runbook: NodeHighMemory

Fired by Prometheus rule [`NodeHighMemory`](../../../docker/prometheus/rules/alerts.yml) — host memory used (`1 - MemAvailable/MemTotal`) above 85% for 15 min, sourced from the `node_exporter` daemon.

## What this means

A specific EC2 instance in the ECS cluster is at memory pressure. `MemAvailable` accounts for reclaimable page cache, so this is "real" pressure — when it crosses 85% the kernel is starting to evict, and OOM-kills follow.

The label `instance` identifies the host.

## Who/what is impacted

Memory-bound services on that host get OOM-killed first (`Killed` exit code from the kernel). For Cabalmail the memory-hungry services are:
- Prometheus (TSDB head, queries, blackbox scrape buffers)
- Grafana (per-user query state)
- Kuma (Node.js heap; grows with monitor count)
- Healthchecks (Django + uWSGI)

Mail tiers (Dovecot, Sendmail) are I/O- and CPU-bound, not memory-bound, and rarely contribute.

## First three things to check

1. **Which task is the heavyweight on this host?**
   ```sh
   INSTANCE_ID=$(aws ec2 describe-instances --filters Name=private-ip-address,Values=<host-ip> --query 'Reservations[0].Instances[0].InstanceId' --output text)
   aws ssm start-session --target "$INSTANCE_ID"
   docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"
   ```
2. **Is anything OOM-killed yet?** On the host:
   ```sh
   journalctl -k --since '1 hour ago' | grep -i 'killed process\|oom'
   ```
   If yes, ECS will already be restarting the task; cross-reference with [container-restart-loop.md](./container-restart-loop.md).
3. **Does the task have a memory cap?** Each mail-tier and monitoring task definition sets `memory` and `memoryReservation`. A task without a `memory` hard limit can starve neighbors:
   ```sh
   aws ecs describe-task-definition --task-definition <family> --query 'taskDefinition.containerDefinitions[].{name:name,reservation:memoryReservation,limit:memory}'
   ```

## Escalation

- **Quick mitigation**: bounce the heaviest task. ECS will reschedule it (potentially on a less-loaded host).
- **Right fix for Prometheus heap growth**: shorter retention or a switch to VictoriaMetrics (mentioned as a fallback in [monitoring-plan.md §3](../../0.7.0/monitoring-plan.md#1-prometheus--alertmanager--grafana)).
- **Right fix for cluster-wide pressure**: larger instance class. The mail tiers fit comfortably in `t3.small`; the monitoring stack does not at scale.
- This is `warning` severity. Sustained pressure escalates to a critical via container restart loops once OOM-killing kicks in.

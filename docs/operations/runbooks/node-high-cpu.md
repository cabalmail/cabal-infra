# Runbook: NodeHighCPU

Fired by Prometheus rule [`NodeHighCPU`](../../../docker/prometheus/rules/alerts.yml) — host CPU above 85% for 15 min, sourced from the `node_exporter` daemon.

## What this means

A specific EC2 instance in the ECS cluster has been near saturation for 15 minutes. The label `instance` identifies the host (Cloud Map A-record / IP).

`node_exporter` runs as a `DAEMON` ECS service so each EC2 host reports independently — this rule fires on a per-host basis, not cluster-wide.

## Who/what is impacted

Tasks running on that EC2 are getting throttled at the kernel level. For Cabalmail:
- Mail-tier tasks slow down (longer IMAP responses, longer queue times).
- Monitoring stack hosts: Prometheus scraping slows, dropping samples; Grafana queries get sluggish.
- The NAT instance is on a separate ASG, not visible here — see [Platform / NAT](../../0.7.0/monitoring-plan.md#platform-ecs-cluster-nat-vpc) for that signal.

## First three things to check

1. **Which container on the host is using the CPU?** ECS doesn't show this directly, but you can SSH (via SSM) to the instance and inspect:
   ```sh
   INSTANCE_ID=$(aws ec2 describe-instances --filters Name=private-ip-address,Values=<host-ip> --query 'Reservations[0].Instances[0].InstanceId' --output text)
   aws ssm start-session --target "$INSTANCE_ID"
   # then on the host:
   docker ps --no-trunc | head
   docker stats --no-stream
   ```
2. **Is it a sustained workload or a runaway?** A continuous 90% over hours on one host with mail tiers usually means a stuck procmail or a tight-loop attempt at brute-forcing IMAP. A slow climb over days points to a memory leak that's now causing GC churn — confirm with [`NodeHighMemory`](./node-high-memory.md).
3. **Is the cluster overprovisioned or underprovisioned overall?** Check the ECS cluster's reservation: if every host is >80%, the cluster needs more capacity (or smaller services). If only one host is hot, something is wrong with that host's tasks specifically.

## Escalation

- **Single-host hotspot**: drain and replace the EC2:
  ```sh
  aws ecs update-container-instances-state --cluster <cluster> \
    --container-instances <ci-id> --status DRAINING
  # wait for tasks to drain, then terminate the EC2; ASG replaces it
  ```
- **Cluster-wide saturation**: scale the ASG up or move to a larger instance class. The monitoring services are memory-heavy, not CPU-heavy — if CPU is the bottleneck, expect mail-tier load (a brute-force attempt is the most common cause; check fail2ban activity).
- This is `warning` severity. Sustained CPU saturation will eventually cause container restart loops or probe failures, both of which escalate to critical.

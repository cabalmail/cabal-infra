# Runbook: NodeDiskSpaceLow

Fired by Prometheus rule [`NodeDiskSpaceLow`](../../../docker/prometheus/rules/alerts.yml) — a non-tmpfs / non-overlay filesystem on a cluster EC2 above 85% used for 15 min.

## What this means

A persistent disk on a cluster instance is filling up. The label `mountpoint` identifies which one. Two common culprits on Cabalmail's EC2 nodes:

- `/` (the EBS root volume) — typically grows because of Docker image churn, container logs, or dockerd's overlay2 garbage.
- `/mnt/efs/...` — *not* this rule's concern. EFS isn't local; it's mounted via NFS and reports through `cloudwatch_exporter` instead.

Bind-mounted EFS access points use `nfs4` fstype, so they're filtered out by the rule's `fstype!~"tmpfs|overlay"` exclusion via Prometheus default behaviour (`fstype=nfs4` doesn't match `tmpfs|overlay` so it isn't excluded — but nfs reports against the EFS file system as a whole, not "this host"). If you see this alert on an `nfs` mountpoint, treat it as an EFS sizing issue and consult [efs-burst-credits-low.md](./efs-burst-credits-low.md) instead.

## Who/what is impacted

A full disk is one of the most catastrophic states a Linux box can be in:
- Docker can't start new containers — every redeploy on this host fails.
- Existing containers die when they try to log or write a tmpfile.
- ECS reports tasks as unhealthy as soon as health checks try to write.

## First three things to check

1. **What's using the space?**
   ```sh
   INSTANCE_ID=$(aws ec2 describe-instances --filters Name=private-ip-address,Values=<host-ip> --query 'Reservations[0].Instances[0].InstanceId' --output text)
   aws ssm start-session --target "$INSTANCE_ID"
   df -h /
   sudo du -shx /var/lib/docker/* 2>/dev/null | sort -rh | head
   sudo du -shx /var/log/* | sort -rh | head
   ```
2. **Are there dangling Docker images?** ECS leaves old images on disk. A simple GC:
   ```sh
   sudo docker image prune -af --filter "until=72h"
   ```
   Don't `docker system prune` blindly — it'll destroy active task volumes if used wrong.
3. **Is journald rotating?** If `/var/log/journal` is the heavy hitter, vacuum it:
   ```sh
   sudo journalctl --vacuum-time=3d
   ```

## Escalation

- If the root volume is undersized for normal operation (8 GB is too small for the monitoring stack hosts), update the launch template: `BlockDeviceMappings[0].Ebs.VolumeSize = 30` and replace the instance via ASG cycle.
- Persistent fill-up over weeks despite GC indicates something is logging excessively. Check `dockerd` and the heaviest containers' log volumes — task-level logs go to CloudWatch via `awslogs` driver, so a host-side log-file accumulation is unusual and probably an entrypoint bug.
- This is `warning` severity. A genuinely full disk (`100%`) tips the host into critical territory immediately — promote the alert and treat it as a `ContainerRestartLoop` precursor.

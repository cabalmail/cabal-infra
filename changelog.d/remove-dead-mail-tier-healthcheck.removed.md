- Removed the Docker HEALTHCHECK from the three mail-tier images (imap,
  smtp-in, smtp-out). It could never pass: the check ran supervisorctl, but no
  tier's supervisord.conf configures an RPC endpoint for it to reach, so the
  Docker daemon marked every container "unhealthy" on the host - and ECS
  ignores image health checks anyway (it only honors healthCheck blocks in the
  task definition, and none are defined). Liveness continues to come from the
  NLB target-group TCP checks on the service ports, which ECS does act on.

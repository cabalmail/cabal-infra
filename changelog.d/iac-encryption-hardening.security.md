- Encryption and IMDS hardening for the mail data plane (IaC quality gates,
  Phase 2.5 remainder). The address-change reconfiguration pipeline is now
  encrypted at rest: the per-tier `cabal-reconfig-*` SQS queues use SSE-SQS,
  and the `cabal-address-changed` SNS topic uses the AWS-managed `aws/sns` key
  (the new/revoke Lambda is granted `kms:GenerateDataKey`/`Decrypt` scoped via
  `kms:ViaService=sns` so publishing keeps working). The NAT instance root
  volume is now encrypted, and the ECS launch template's IMDS hop limit drops
  from 2 to 1 - the tasks run in `awsvpc` mode and read credentials from the
  task-role endpoint rather than the host IMDS, so a compromised container can
  no longer reach the host instance role.

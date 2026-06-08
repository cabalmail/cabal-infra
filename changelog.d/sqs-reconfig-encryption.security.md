- The per-tier `cabal-reconfig-*` SQS queues (the address-change
  reconfiguration pipeline) are now encrypted at rest with SSE-SQS. The
  SQS-owned key needs no management, and SNS->SQS delivery and the reconfigure
  sidecar consumers are transparent to it.

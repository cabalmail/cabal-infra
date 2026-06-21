- The mail-tier, monitoring, and sinkhole ECR repositories now carry a
  per-repo policy that restricts image pull. They deny
  `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`, and
  `ecr:BatchCheckLayerAvailability` to every principal except their
  legitimate pullers: the mail tiers and sinkhole to the ECS task
  execution role, each monitoring repo to its own `cabal-<tier>-execution`
  role, plus the shared container-instance role and the CI/CD deploy role
  on every repo. Previously any account principal holding ECR permissions
  could pull them. The certbot-renewal repo is intentionally left to its
  Lambda-service-managed policy (a Terraform-owned policy would fight
  Lambda's auto-injected image-retrieval statement). Completes the ECR
  posture work in the 0.10.x identity and IAM hardening plan.

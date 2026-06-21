- The mail-tier and sinkhole ECR repositories now carry a per-repo policy
  that restricts image pull. They deny `ecr:GetDownloadUrlForLayer`,
  `ecr:BatchGetImage`, and `ecr:BatchCheckLayerAvailability` to every
  principal except the ECS task execution role, the shared
  container-instance role, and the CI/CD deploy role; previously any
  account principal holding ECR permissions could pull them. The
  monitoring repos are left unrestricted (their per-tier execution roles
  exist only when monitoring is enabled, and the repos sit empty while it
  is the default-off warm spare), and the certbot-renewal repo is left to
  its Lambda-service-managed policy. Advances the ECR posture work in the
  0.10.x identity and IAM hardening plan.

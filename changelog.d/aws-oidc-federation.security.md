- CI now authenticates to AWS with GitHub OIDC instead of long-lived
  access keys. Every AWS-touching workflow (infra, app, destroy, quiesce,
  register-tfv, image-scan, nat_ami_build) requests an OIDC token
  (`id-token: write`) and assumes a per-environment `cicd` IAM role via
  `aws-actions/configure-aws-credentials`; the static
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets and the
  `deploy_lambda` CLI profile are gone. Setup is by hand per account (an
  OIDC provider + `cicd` role with a repo/environment-scoped trust
  policy) and a per-environment `AWS_DEPLOY_ROLE_ARN` variable; see
  `docs/aws.md`, `docs/github.md`, and `docs/terraform.md`.

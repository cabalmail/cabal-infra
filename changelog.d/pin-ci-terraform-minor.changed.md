- **CI Terraform pinned to a minor line.** Every workflow that runs
  Terraform (`infra.yml`, `quiesce.yml`, `destroy_terraform.yml`,
  `lint.yml`) now installs `~1.16` instead of `latest`. Patch releases
  still flow automatically; a new minor reaches the apply path only
  through a deliberate PR that bumps all of the setup steps together.

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Apple clients no longer surface a `"No mailbox selected"` error when
  archiving from the message list or opening a message
  ([#356](https://github.com/cabalmail/cabal-infra/issues/356)).
  `LiveImapClient.select(...)` caches the SELECTed mailbox to skip
  redundant SELECT round-trips, but the cache could go stale: per
  RFC 3501 §6.3.1, a failed SELECT (folder deleted/renamed by another
  client, transient server NO) leaves the connection in AUTHENTICATED
  state, while the actor still believed it was selected on the prior
  mailbox. The next operation in that folder skipped SELECT and the
  server rejected the bare FETCH/STORE/MOVE.

  Two changes:
  1. `select(...)` now clears `selectedFolder` when the SELECT command
     itself fails, matching the RFC-defined server transition.
  2. `withTransportRetry` recognizes a `"No mailbox selected"` server
     response as a recoverable cache-desync, drops the cache, and
     retries the operation once before surfacing the error.

## [Unreleased]

## [0.9.7] - 2026-05-03

### Changed
- CI/CD deploy workflows (`app.yml`, `infra.yml`) now only fire on the
  three named branches: `main` (prod), `stage` (stage), and
  `development` (development). Pushes from feature branches or tags no
  longer trigger an automatic deploy to development. The manual
  `destroy_terraform.yml` and `quiesce.yml` workflows refuse to run
  from any other branch as well.
- The `claude` issue-label automation now opens PRs against `stage`
  rather than the default branch, so promotion to prod is always a
  deliberate second step.

### Fixed
- Grafana panels that had been "no data" since the monitoring stack
  shipped now populate. Five separate bugs:
  - **API Gateway alerts and per-API-name aggregation**: the `apiname`
    label filter in `Lambda5xxSpike` and the API Gateway dashboard
    didn't match anything. cloudwatch_exporter v0.16.0 snake_cases
    dimension labels (`ApiName` -> `api_name`); only the unrelated
    aggregation by a non-existent label kept the request-count panel
    from looking blank. Renamed every reference to `api_name`.
  - **AWS Services dashboard "ECS RunningTaskCount per service"**: the
    metric was scraped from `AWS/ECS`, but `RunningTaskCount` /
    `DesiredTaskCount` / `PendingTaskCount` actually live in the
    `ECS/ContainerInsights` namespace (Container Insights is enabled
    on the cluster). Moved the three metrics to that namespace in
    `docker/cloudwatch-exporter/config.yml`, updated the dashboard to
    `aws_ecs_containerinsights_running_task_count_average`, and fixed
    the `ContainerRestartLoop` alert to match.
  - **Frontend dashboard CloudFront panels**: covered by a new
    cloudwatch_exporter task pinned to `us-east-1`
    (`cabal-cloudwatch-exporter-us-east-1`), since CloudFront emits
    metrics exclusively in that region and v0.16.0 has no per-metric
    region override. New ECS task definition + service in
    `terraform/infra/modules/monitoring/exporters.tf`, new Cloud Map
    registration, new Prometheus `cloudwatch-us-east-1` scrape job,
    and a new minimal CloudFront-only config
    (`docker/cloudwatch-exporter/config-us-east-1.yml`) baked into
    the existing image. App-deploy script
    (`.github/scripts/deploy-ecs-service.sh`) now accepts a service-
    name override so the same image tag rolls onto both services;
    `app.yml` calls it twice for the cloudwatch-exporter tier. Also
    fixed the dashboard's `aws_cloudfront_5_xx_error_rate_average` ->
    `aws_cloudfront_5xx_error_rate_average` (the CloudWatch metric is
    `5xxErrorRate`, lowercase, which snake-cases without the extra
    underscore that `5XXError` produces).
  - **Mail Tiers "TLS days to expiry - IMAP 993"**: the blackbox
    `tcp_connect` probe never initiates a TLS handshake, so
    `probe_ssl_earliest_cert_expiry` was permanently absent. Split
    the Prometheus blackbox jobs in two: `blackbox-tcp` keeps port 25
    (plaintext) and 587 (STARTTLS, blackbox doesn't drive STARTTLS),
    while a new `blackbox-tls` job using the existing `tcp_tls`
    blackbox module covers the implicit-TLS ports 993 (IMAP) and 465
    (SMTP submission), populating the cert-expiry metric.
- Updated `docs/monitoring.md` accordingly: the "What populates when"
  section no longer marks CloudFront panels as permanently empty, the
  scrape-target inventory in step 18 reflects the second
  cloudwatch-exporter and the split blackbox jobs, and a new
  "Verifying the data pipeline" section documents how to confirm
  CloudWatch -> exporter -> Prometheus -> Grafana is sound and how to
  inject synthetic data into each "no data" panel to prove it lights
  up.

### Changed
- Broadened `docker/cloudwatch-exporter/config.yml` EFS coverage with
  `StorageBytes`, `TotalIOBytes`, `DataReadIOBytes`, and
  `DataWriteIOBytes`. AWS recently changed the default EFS throughput
  mode to `elastic`, which doesn't emit `BurstCreditBalance` or
  `PercentIOLimit`; the new metrics are throughput-mode-agnostic so
  the AWS Services dashboard has a working saturation signal
  regardless of which mode the file system is in.
- Enabled ECS Exec on `cabal-cloudwatch-exporter`,
  `cabal-cloudwatch-exporter-us-east-1`, and `cabal-blackbox-exporter`
  so an operator can drop into a shell on those tasks for
  data-pipeline debugging. Same `enable_execute_command = true` plus
  `ssmmessages:*` IAM grant pattern that Prometheus, Grafana, Kuma,
  and Healthchecks already used. After Terraform apply, existing
  tasks need a `--force-new-deployment` to pick up the flag (the
  flag only applies at task-launch time).

## [0.9.6] - 2026-05-01

### Fixed
- Restored the shared Lambda layer's first-party module (`helper.py`)
  in CI builds. The 0.9.5 lambda-api parallelisation extracted the
  per-function build into `build-api-one.sh` but only carried over the
  `rm -rf ./python` + `pip install -t ./python` steps; the `./src/.`
  -> `./python/` copy that 0.9.4 added (so the wipe couldn't delete
  helper.py) was left behind in the now-defunct sequential loop in
  `build-api.sh`. Once that loop was removed in the build-api.sh
  leftover-loop fix, every published layer shipped third-party deps
  only, and every IMAP-backed Lambda (`list_messages`, `list_envelopes`,
  `fetch_message`, `send`, the folder/flag/move endpoints, the
  IMAP-touching `revoke`) crashed at import with `ModuleNotFoundError:
  helper`. The webmail surfaced this as "Unable to load list of
  messages."; dedicated IMAP/SMTP servers were unaffected because they
  don't share that code path. The copy step now lives in
  `build-api-one.sh` itself, where the wipe and pip install live.

### Changed
- Updated CLAUDE.md to reflect 0.9.x as in progress.
- Phase 7 of the build/deploy simplification plan
  (`docs/0.9.0/build-deploy-simplification-plan.md`): operator-facing
  documentation that referenced the deleted workflows now points at
  the new pipeline. `docs/quiesce.md`, `docs/monitoring.md`, the
  `lambda-errors` and `container-restart-loop` runbooks under
  `docs/operations/runbooks/`, the comment in
  `terraform/infra/modules/lambda_layers/main.tf`, the path comment
  in `.github/scripts/record-lambda-hashes.sh`, and the durability /
  resume warning strings in `.github/workflows/quiesce.yml` all
  rename `terraform.yml` -> `infra.yml`, `lambda_api_python.yml` ->
  the `lambda-api` job in `app.yml`, `docker.yml` -> the `docker`
  job in `app.yml`, and so on. The container-restart-loop runbook's
  rollback recipe is rewritten to call `deploy-ecs-service.sh`
  directly rather than the now-deleted SSM-then-Terraform path.
  
## [0.9.5] - 2026-05-01

### Changed
- Phase 6 of the build/deploy simplification plan
  (`docs/0.9.0/build-deploy-simplification-plan.md`): cutover. The
  legacy `docker.yml`, `lambda_api_python.yml`, `lambda_counter.yml`,
  `react.yml`, and `bootstrap.yml` workflows are deleted. Pushes to
  `docker/**`, `lambda/**`, and `react/admin/**` now drive `app.yml`
  exclusively, which builds artifacts in parallel and deploys
  out-of-band via the AWS CLI without re-entering Terraform.
  `terraform-legacy.yml` (the renamed legacy Terraform pipeline kept
  as a one-release escape hatch in 0.9.4) is also deleted, taking the
  `repository_dispatch: trigger_build` listener with it. Phase 7
  housekeeping items from the original plan (removing `workflow_call`
  callers and the legacy interface) are satisfied automatically by
  the file deletions.
- `app.yml` gains push triggers and a `dorny/paths-filter@v3` step in
  its `setup` job that scopes per-push runs to only the changed areas
  (`docker`, `lambda_api`, `lambda_counter`, `lambda_certbot`,
  `react`). The `workflow_dispatch` `areas` input is preserved as a
  manual override so an operator can still force a partial or full
  re-deploy without a fresh push. Per-branch `environment:` bindings
  on every AWS-touching job are unchanged, so the existing required-
  reviewer gate on prod carries over.
- Monitoring tier ECR repositories (`cabal-uptime-kuma`, `cabal-ntfy`,
  `cabal-healthchecks`, `cabal-prometheus`, `cabal-alertmanager`,
  `cabal-grafana`, `cabal-cloudwatch-exporter`,
  `cabal-blackbox-exporter`, `cabal-node-exporter`) are now created by
  a dedicated `aws_ecr_repository.monitoring` resource in
  `terraform/infra/modules/ecr/main.tf` with `lifecycle {
  prevent_destroy = true }`. Toggling `var.monitoring` off or trimming
  the docker matrix in `app.yml` is now a no-op against these repos
  rather than a destroy, so historical images cannot be deleted by
  accident. State migration is handled by `moved {}` blocks; the
  resource rename is state-only.
- `CLAUDE.md` workflow table updated to reflect the two-workflow model
  (`app.yml` + `infra.yml`) plus the surviving manual / scheduled
  workflows.

## [0.9.4] - 2026-04-30

### Added
- Phase 4 of the build/deploy simplification plan
  (`docs/0.9.0/build-deploy-simplification-plan.md`): bootstrap
  placeholders so a brand-new environment can apply
  `terraform/infra` end-to-end without `app.yml` having ever pushed
  an image or zip. Every `aws_ecs_task_definition` (the three mail
  tiers in `modules/ecs` and the nine monitoring tiers in
  `modules/monitoring`) now resolves its container image through a
  per-tier `local.<...>_image` map: when `var.image_tag` equals the
  sentinel `bootstrap-placeholder`, the task def points at
  `public.ecr.aws/nginx/nginx:stable` instead of the empty ECR repo.
  `cabal-certbot-renewal` (container-image Lambda) follows the same
  pattern with `public.ecr.aws/lambda/python:3.13-arm64` as the
  placeholder. Phase 1's `ignore_changes = [container_definitions]`
  and phase 2's `ignore_changes = [image_uri]` keep the next
  `app.yml` deploy from being rolled back on a topology-only apply.
- `.github/scripts/upload-stub-lambdas.sh` materialises
  `lambda/<func>.zip` and the `.base64sha256` sidecar in S3 for any
  function whose pair is missing - the rest of the
  `terraform/infra` Lambda fleet (api `cabal_method` calls,
  `process_dmarc`, `assign_osid`, `alert_sink`,
  `backup_heartbeat`, `healthchecks_iac`, the shared `python`
  layer) reads the sidecar at plan time, so the very first apply
  needs *something* in S3 even though no real build has run. The
  stub is a deterministic zip whose handler raises
  `NotImplementedError` so a forgotten "real deploy" surfaces in
  CloudWatch instead of returning success. Steady-state behaviour
  is a no-op: every function's pair is already in S3, every
  `head-object` is a hit, nothing is uploaded. The script is laid
  down here for phase 5's `infra.yml` to call as a pre-apply step.
- Phase 5 of the build/deploy simplification plan
  (`docs/0.9.0/build-deploy-simplification-plan.md`): new
  `.github/workflows/infra.yml` replaces `terraform.yml` +
  `bootstrap.yml` as the canonical infrastructure pipeline. It owns
  both the bootstrap (`terraform/dns`) stage and the main
  (`terraform/infra`) stage in a single workflow gated by a
  `dorny/paths-filter@v3` step: a push that only touches
  `terraform/infra/**` skips the bootstrap jobs in 0s, and a push
  that touches `terraform/dns/**` runs bootstrap before the main
  apply. `workflow_dispatch` exposes a `bootstrap` boolean input that
  forces the bootstrap stage when neither path filter would. Inherits
  the per-branch `environment:` mapping (`main`->prod,
  `stage`->stage, other->development) on every AWS-touching job, so
  the existing required-reviewer gate on `prod` carries over
  unchanged. Adds `concurrency: { group: infra-${{ github.ref }},
  cancel-in-progress: false }` so back-to-back applies serialise on
  the state lock instead of racing.
- `.github/scripts/post-apply-update-services.sh` and a `post_apply`
  job in `infra.yml` that runs it. Phase 1 (shipped in 0.9.3) added
  `lifecycle { ignore_changes = [task_definition] }` to every
  `aws_ecs_service` so out-of-band app deploys are not rolled back by
  topology-only Terraform applies; the trade-off was that a Terraform
  topology change (cpu/memory/env/IAM) registers a new task-def
  revision but the service stays pinned to the old one. The script
  walks every service on `cabal-mail`, compares the family head
  against the service's current revision, and calls `aws ecs
  update-service` to roll forward only when the head has advanced.
  Steady-state no-op; closes the gap noted in 0.9.3 between
  Terraform-driven topology changes and out-of-band deploys.

### Fixed
- `app.yml`'s `setup` job now declares `environment: ${{ ... }}`
  matching the per-branch dev/stage/prod mapping the rest of the
  workflow already uses, so its `compute-matrix` step can read
  `vars.TF_VAR_MONITORING`. The flag is set on the GitHub
  environment, not at the repo level; without the binding, the
  unbound `setup` job saw an empty value and the `if` fell through
  to just the three core docker tiers - so prod runs were quietly
  skipping all nine monitoring tier builds even with monitoring
  enabled.
- Webmail message list (and every other IMAP-backed endpoint) was
  failing because the deterministic-build follow-up to phase 2
  (`bff24dcf`) added `rm -rf ./python` before each `pip install` in
  `.github/scripts/build-api.sh`. For the shared Lambda layer at
  `lambda/api/python/`, that wipe also deleted the layer's only
  first-party module - `python/python/helper.py` - leaving the
  rebuilt layer zip with only the third-party deps. Every Lambda
  that does `from helper import …` (`list_messages`,
  `list_envelopes`, `fetch_message`, `send`, the folder/flag/move
  endpoints, and the IMAP-touching `revoke`) then crashed at import
  with `ModuleNotFoundError`, while the dedicated IMAP/SMTP servers
  - which never touched this code path - kept working. Fix moves
  the layer's first-party sources to a sibling `lambda/api/python/src/`
  directory that the wipe never sees and copies `./src/.` into
  `./python/` after `pip install` finishes, so the layer ships both
  third-party deps and `helper.py`. Issue #346.

### Changed
- `lambda-api` build and deploy are now parallel. `build-api.sh` was
  refactored into a thin driver that enumerates `lambda/api/*` dirs
  and dispatches a new `build-api-one.sh` per dir under `xargs -P
  ${BUILD_JOBS:-8}`; `app.yml`'s deploy step does the same with
  `xargs -P ${DEPLOY_JOBS:-8}` over the eligible-function list,
  calling `deploy-lambda-zip.sh` per function. Eligibility checks
  (skipping the shared `python` layer dir, the `healthchecks_iac`
  legacy path, and any function whose Terraform module is gated off
  in this environment) stay serial since they're a tight sequence
  of cheap `aws lambda get-function` calls. AWS does not rate-limit
  `update-function-code` across distinct function names at the
  scale we'd hit, so the deploy half is dominated by the slowest
  single `wait function-updated` rather than their sum. Drops the
  `lambda-api` job from ~15 min to roughly the slowest function's
  build-and-deploy time.
- `.github/workflows/terraform.yml` renamed to
  `.github/workflows/terraform-legacy.yml`. The `push` trigger is
  stripped so a push to `terraform/infra/**` now drives `infra.yml`
  rather than re-entering Terraform via the legacy file.
  `workflow_dispatch` and `repository_dispatch` are kept as manual
  escape hatches for one release cycle in case `infra.yml` needs to
  be rolled back. `workflow_call` is preserved for the same window so
  the still-existing chain from `docker.yml` /
  `lambda_api_python.yml` / `lambda_counter.yml` keeps working; phase
  6 deletes those callers and phase 7 deletes the now-unused
  `workflow_call` interface here.
- `docker.yml`, `lambda_api_python.yml`, and `lambda_counter.yml`
  updated their `uses:` references from
  `./.github/workflows/terraform.yml` to
  `./.github/workflows/terraform-legacy.yml` so the legacy
  build->terraform chain keeps working through the dual-pipeline
  window. These files are deleted in phase 6.

### Deprecated
- `.github/workflows/terraform-legacy.yml` is the renamed legacy
  Terraform pipeline, kept only as a manual escape hatch in case
  `infra.yml` needs to be rolled back during the dual-pipeline
  window. It will be removed in the next release alongside phase 6's
  cutover (which also deletes `docker.yml`, `lambda_api_python.yml`,
  `lambda_counter.yml`, `react.yml`, and `bootstrap.yml`). Do not
  invoke it for routine deploys: push-driven infra changes flow
  through `infra.yml` and app deploys flow through `app.yml`.

## [0.9.3] - 2026-04-30

### Changed
- Phase 1 follow-up: every `aws_ecs_service` (3 mail-tier services in
  `terraform/infra/modules/ecs/services.tf` plus 9 monitoring
  services across `modules/monitoring/`) now has `lifecycle {
  ignore_changes = [task_definition] }`. Phase 1 ignored
  `container_definitions` on the task-def resources, but the
  services still referenced `aws_ecs_task_definition.<name>.arn`,
  so after `app.yml` registered a new revision out-of-band and
  rolled the service forward, every subsequent Terraform plan
  wanted to roll the service back to the (state-bound) revision the
  task-def resource was last applied at. Trade-off: a Terraform
  topology change (cpu/memory/env/IAM) that registers a new
  revision will not auto-roll the service either; phase 5's
  `infra.yml` will add a post-apply `update-service` step keyed off
  the freshly-registered revision.
- `build-api.sh` and `build-counter.sh` now produce byte-stable zips
  for the same source tree across runs. The python Lambda layer
  (`lambda/api/python/`) was the chokepoint: a non-deterministic
  zip meant the layer's `source_code_hash` changed on every CI run,
  forcing a new `aws_lambda_layer_version` and a 30+ Lambda
  in-place update on the next Terraform plan to rotate every
  function's `layers` attribute. Build now sets
  `SOURCE_DATE_EPOCH`, passes `pip install --no-compile`, scrubs
  `__pycache__/*.pyc/direct_url.json`, normalises file modes
  (0755 dirs / 0644 files), and sorts under `LC_ALL=C`. Same
  source-and-pinned-deps now yields the same zip bytes.

### Added
- Phase 3 of the build/deploy simplification plan
  (`docs/0.9.0/build-deploy-simplification-plan.md`): new
  `.github/workflows/app.yml` builds every application artifact in
  parallel and deploys directly to running infrastructure via the AWS
  CLI - no Terraform on the deploy path. Triggered on
  `workflow_dispatch` only at this phase, with an `areas` input
  (default `all`) that scopes the run to any subset of `docker`,
  `lambda_api`, `lambda_counter`, `lambda_certbot`, `react`. The
  legacy `docker.yml`, `lambda_api_python.yml`, `lambda_counter.yml`,
  and `react.yml` keep running unchanged so both pipelines coexist
  during validation; phase 6 cuts the legacy workflows over and adds
  push triggers to `app.yml`. The docker matrix already drops the
  nine monitoring tiers when `vars.TF_VAR_MONITORING != 'true'` so
  manual validation does not pay arm64 build minutes for images
  nothing deploys. `concurrency: { group: app-${{ github.ref }},
  cancel-in-progress: false }` serialises overlapping app deploys per
  ref so back-to-back runs roll services in order rather than racing.
- `.github/scripts/deploy-ecs-service.sh` is the ECS half of the
  out-of-band deploy path. Given a tier and an image tag it clones
  the running task definition for `cabal-<tier>` on the `cabal-mail`
  cluster, rewrites every container whose ECR repo basename is
  `cabal-<tier>` to point at the new tag, registers a new revision
  via `aws ecs register-task-definition`, and rolls the service via
  `aws ecs update-service`. Phase 1's lifecycle clause
  (`ignore_changes = [container_definitions]`) keeps a topology-only
  Terraform apply from clobbering the new revision; phase 1's
  `refresh-ssm-from-running.sh` keeps `/cabal/deployed_image_tag` in
  lockstep with whatever the script just deployed.
- `.github/scripts/deploy-lambda-zip.sh` and
  `.github/scripts/deploy-lambda-image.sh` are the Lambda half. The
  zip helper assumes `build-api.sh` / `build-counter.sh` has
  uploaded `<func>.zip` and `<func>.zip.base64sha256` to
  `s3://admin.${TF_VAR_CONTROL_DOMAIN}/lambda/`, then calls
  `aws lambda update-function-code --s3-bucket ... --s3-key ...` and
  waits for the update to settle. The image helper does the
  equivalent for `cabal-certbot-renewal` via `--image-uri`. Both
  refuse to deploy a function that does not yet exist in the account
  so misconfigured runs fail loudly. The `lambda-api` deploy step in
  `app.yml` walks every directory in `lambda/api/` except `python`
  (the shared layer) and `healthchecks_iac` (kept on the legacy
  in-Terraform invocation flow per phase 2's note).

## 0.9.2 - 2026-04-29

### Changed
- Phase 2 of the build/deploy simplification plan
  (`docs/0.9.0/build-deploy-simplification-plan.md`): every S3-source
  `aws_lambda_function` resource (the api `cabal_method` calls, the
  `process_dmarc` ingester, the `assign_osid` Cognito post-confirmation
  trigger, and the `alert_sink` and `backup_heartbeat` monitoring
  Lambdas) now has `lifecycle { ignore_changes = [s3_key,
  s3_object_version, source_code_hash] }`. The container-image
  `cabal-certbot-renewal` Lambda has `lifecycle { ignore_changes =
  [image_uri] }`. `healthchecks_iac` is intentionally excluded -
  `aws_lambda_invocation` triggers on its `source_code_hash` and
  freezing that trigger would block config.py changes from
  propagating; phase 3 will replace its in-Terraform invocation flow
  with an explicit out-of-band `aws lambda invoke` after a code
  deploy. Steady-state no-op until phase 3 introduces out-of-band
  Lambda deploys; protects forward updates from being rolled back by
  topology-only applies once they do.

### Added
- Value for `SITE_LOGO_URL` to heartbeat service configuration.
- `.github/scripts/record-lambda-hashes.sh` queries every S3-source
  Lambda function in the account via `aws lambda list-functions` and
  writes their `CodeSha256` values to
  `terraform/infra/.terraform/lambda-pinned.tfvars` as the
  `lambda_pinned_hashes` map variable. Wired into the `terraform.yml`
  plan and apply jobs after `terraform init` so plan and apply both
  receive a consistent snapshot of running code identity. The new
  variable is declared in `terraform/infra/variables.tf` with default
  `{}`; it is reserved for phase 3 wiring and not yet consumed by
  individual Lambda resources, so the script is a steady-state no-op
  on the legacy pipeline.

### Fixed
- NAT-instance Terraform plan is now idempotent. `aws_instance.nat` in
  `terraform/infra/modules/vpc/nat.tf` ignores changes to its computed
  `public_ip` / `public_dns`, which the EIP association overwrites
  out-of-band and the AWS provider reported as drift on every plan.
  Also dropped the explicit `base64encode(...)` wrapper around the
  cleartext NAT-instance `user_data` heredoc; the provider now base64-
  encodes internally, silencing the deprecation warning about a
  base64-encoded value passed to the cleartext `user_data` argument.

## [0.9.1] - 2026-04-29

### Changed
- Phase 1 of the build/deploy simplification plan
  (`docs/0.9.0/build-deploy-simplification-plan.md`): every
  `aws_ecs_task_definition` resource in `terraform/infra/modules/ecs`
  and `terraform/infra/modules/monitoring` (12 task defs across the
  three mail tiers and nine monitoring tiers) now has
  `lifecycle { ignore_changes = [container_definitions] }`. This is a
  no-op in steady state and prepares for phase 3, when application
  deploys will mutate task-def container definitions out-of-band via
  `aws ecs register-task-definition` instead of going through Terraform.

### Added
- `.github/scripts/refresh-ssm-from-running.sh` reconciles
  `/cabal/deployed_image_tag` with the image tag actually running on
  the canonical mail-tier service (`cabal-imap`) before the Terraform
  plan job runs. Wired into `terraform.yml`'s plan job before the
  existing `update-image-tag-in-ssm` step so a topology-only apply
  that regenerates `container_definitions` cannot silently roll back
  an out-of-band app deploy. Exits 0 cleanly when the cluster or
  service does not yet exist (first-run case), so the script is safe
  on a brand-new environment.

## [0.9.0] - 2026-04-29

### Added
- `quiesce` GitHub workflow (`.github/workflows/quiesce.yml`)
  scales a non-prod environment's running compute to zero to save
  cost, or restores it. `workflow_dispatch` only, with `environment`
  (development | stage) and `action` (down | up) inputs. Refuses to
  run from `main` and refuses any branch/environment mismatch. New
  root-level Terraform variable `quiesced` (default `false`) is
  threaded through the `ecs`, `monitoring`, and `vpc` modules and
  gates: every mail-tier and monitoring ECS service `desired_count`,
  the `smtp_in` and `smtp_out` Application Auto Scaling target
  bounds, the ECS-instance ASG `min_size`/`desired_capacity`/
  `max_size` and `protect_from_scale_in`, the ECS capacity provider
  `managed_termination_protection`, the NAT instances and NAT
  gateway counts, and the private subnet default route. State-bearing
  resources (DynamoDB, EFS, S3, Cognito, Route 53, ACM, NLB,
  CloudFront, Lambda) are unaffected. New operations doc at
  `docs/quiesce.md`, linked from `docs/operations.md`.
- `terraform.yml` tfvars step now writes `quiesced = ${{ vars.TF_VAR_QUIESCED || 'false' }}`,
  so setting `TF_VAR_QUIESCED=true` on a GitHub Environment makes the
  quiesced state durable across pushes and other terraform workflow
  runs.

## [0.8.2] - 2026-04-29

### Added
- Confirmation modal before address revocation in the React app. The
  Addresses rail (email client sidebar) previously revoked immediately
  on click; it now opens an `alertdialog` modal with a destructive
  "Revoke" button. The admin "All Addresses" view replaces its
  `window.confirm()` with the same styled modal for consistency. New
  shared `ConfirmDialog` component under `src/ConfirmDialog/`. The
  Apple client already had a `confirmationDialog` for revocation and
  is unchanged. Closes #333.

### Changed
- Replaced the remaining browser-native `window.confirm()` prompts on
  destructive actions across the React app with the shared
  `ConfirmDialog` so all confirmations share a single styled
  presentation: user delete and address-unassign in the Users admin
  view, address-unassign in the All Addresses admin view, and the
  Markdown/Rich Text replace prompts in the compose editor.

## [0.8.1] - 2026-04-28

### Added
- Workflow to trigger Claude Code on new issues labeld `claude`.

## [0.8.0] - 2026-04-28

A ground-up redesign of the React webmail against the Stately design system (`docs/0.8.0/redesign-plan.md`). New token foundation, three-pane layout with resizable boundaries, lucide iconography, redrawn Reader and Compose surfaces, persisted user preferences, keyboard shortcuts, and a responsive mobile/tablet/desktop layout.

### Added

- **React redesign — Token foundation + Nav shell** (§4a):
  - Stately light/dark token set in `AppLight.css` / `AppDark.css` (`--bg`, `--reader-bg`, `--pane-bg`, `--surface`, `--surface-hover`, `--border`, `--border-faint`, `--ink` / `-soft` / `-quiet` / `-danger`, `--accent` / `-fg` / `-ink` / `-soft`, `--shadow-menu` / `-modal` / `-compose`), keyed off `:root[data-direction="stately"]` with dark variants under `@media (prefers-color-scheme: dark)`.
  - Six accent palettes in both light and dark (`ink`, `oxblood`, `forest`, `azure`, `amber`, `plum`) keyed off `[data-accent="…"]`; default `forest`.
  - Theme-independent font, radius, and density tokens (`data-density="compact|normal|roomy"`); Source Serif 4 400/600/700, Inter 400/500/600/700, and IBM Plex Mono 400 loaded via `<link>` in `index.html`.
  - `useTheme` hook — theme/accent/density with localStorage persistence and `data-*` attribute sync onto `<html>`.
  - `Nav/` rebuilt: 56px top bar, wordmark (accent logo tile + "Cabalmail") left, centered search input with a Lucide search glyph and mono `⌘K` chip, theme toggle, and avatar menu with accent swatches + the existing view switcher (Email / Folders / Addresses / Users / DMARC / Log out). Logged-out state shows Log in + Sign up.
  - `lucide-react` added; `Search` / `Sun` / `Moon` / `Check` used in the new Nav.
- **React redesign — Left rail (Folders + Addresses)** (§4b):
  - Folders with lucide icons, collapsible FOLDERS section, inline add row, selected-row left-edge 2px accent rail + `--surface-hover` fill.
  - Addresses with stable hash-to-swatch pills (djb2 → 4 accent swatches, case-insensitive), filter input, and `+ New address` row that opens the existing request modal.
  - Clicking an address writes a shared filter key on `Email`. Left rail total width 280px.
  - New utils: `utils/addressSwatch.js` (djb2 → swatch), `utils/folderMeta.js` (system-kind/label classification + §4b ordering).
- **React redesign — Message list + bulk mode** (§4c):
  - Middle-pane header (60px): folder title in display 24px, "N of M" count, **All / Unread / Flagged** pill tabs, sort strip.
  - `Envelope.jsx` rewired: 56px compact row, 8px leading rail (6px unread dot / checkbox in bulk mode), From line (13px, weight keyed to read state), Subject line (serif 14px), relative time (today → "3h", yesterday → "Yesterday", older → day-of-week, >1wk → "Apr 17"), trailing meta icons.
  - Bulk mode: header swaps to selection count + Archive / Move / Mark read/unread / Flag / Delete + ✕ exit. Shift+click range-select.
  - Empty state: centered mono 13px `--ink-quiet`, "Inbox zero." with filter-empty variant.
  - New state bags on `App.jsx`: `filter`, `sortKey`, `sortDir`, `bulkMode`, `selected`.
- **React redesign — Reader core** (§4d):
  - Action bar (48px sticky): Reply / Reply all / Forward (icon + label), separator, Archive / Move / Delete / Flag / Mark unread (icon-only), overflow ⋯ right.
  - Header block: subject in display 28px, sender name + `<email>`, "to …" line, right-aligned timestamp, 40px accent-soft avatar with initials.
  - Body: rich HTML renders in a sandboxed `<iframe srcdoc=…>` (`allow-same-origin` without `allow-scripts`) with a post-load height probe; plain-text alternative renders as `<pre>` with `white-space: pre-wrap`, `var(--font-reader)`, `var(--density-leading)`. Body max-width 720px, centered.
  - Attachments block: "Attachments (N)" heading, rows with 28px extension badge colored per family (pdf=oxblood, image=azure, archive=amber, doc=forest, default=ink), filename + size, download icon, row hover `--surface-hover`.
  - Overflow menu FORMAT group: **Rich (HTML)** / **Plain text alternative** checkable items. `readerFormat` state ('rich' | 'plain', falls back to 'plain' if no HTML part) lifted into `App.jsx`.
- **React redesign — Reader advanced surfaces** (§4d):
  - **View source modal** — 880×80vh, `--shadow-modal`, `--radius-lg`. Header with "Message source" label + wrapped subject (ellipsis at 48ch) + Full / Headers / Body segmented control (selected = `--accent` fill) + Copy (→ clipboard) + Save .eml (→ `<subject>.eml` with `message/rfc822`) + close. Headers colorized via `<span class="hdr-name">`. RFC-822 parsing (header folding, first blank-line boundary) lives in `utils/emlSource.js`.
  - **Match theme** — with Rich mode + Match theme both on, inject a `<style>` block into the iframe's `<head>` setting `body` background / color / font-family to literal token values resolved via `getComputedStyle(document.documentElement)` (CSS custom properties don't cross the iframe boundary). Also applies a naive background-neutralization pass (`[style*="background: #fff"]` and variants → `--reader-bg`).
  - **Rest of the overflow menu**: View source, Show original headers (reuses the modal pre-set to Headers), Forward as attachment (stub), Print… (`window.print`), Archive, Mark as spam (moves to Junk), Block sender (danger, stub). Arrow-key / Home / End keyboard nav + focus-return to trigger on close.
  - Raw source lazy-loaded on first modal open via the pre-signed URL already returned by `fetch_message` (`message_raw`); `ApiClient.getRawMessage(url)` added so axios' response transform doesn't JSON-parse the eml bytes. `ReaderBody` gains a `matchTheme` prop and re-resolves the injected style whenever the toggle changes.
- **React redesign — Compose window** (§4e):
  - Floating 600×560 card pinned bottom-right with 24px offset, `--shadow-compose`, `--radius-xl`, 44px chrome (minimize / expand / close), 180ms slide-in animation. The existing TipTap rich editor (and Markdown tab) is retained inside the new chrome.
  - `composeFromAddress` state bag on `App.jsx`; the From picker reads it as the default for a freshly-opened window and writes back on selection so the next window inherits the user's last choice.
  - To / Cc / Bcc rows with 48px right-aligned labels. Cc / Bcc hidden behind a toggle on the To row. Recipient chips render inline; type-to-add preserved.
  - Bottom bar: accent Send button ("Sending…" while inflight), paperclip icon stub, "Saved just now" autosave label (local timestamp-only — no draft API yet), and Discard. Esc minimizes; Cmd/Ctrl+Enter sends from any field inside the window.
  - Multi-window: `Email/index.jsx` maintains a `composeWindows` array. Each window gets a unique id; `stackIndex` drives an inline right-offset so they stack horizontally with 8px gaps.
- **React redesign — Auth screens + preferences persistence + keyboard shortcuts**:
  - **Auth (§§1–3)**: Login, SignUp, ForgotPassword, Verify, and ResetPassword rebuilt on a shared `AuthShell` (header, footer, eyebrow + title, narrow/wide variants). SignUp grows a 4-segment password-strength meter and inline validators for username/phone/password/confirm; Login gains a Show/Hide password adornment + Forgot-password hint + Sign-up link; ForgotPassword branches on a lifted `submitted` flag to render a "Check your phone" success state with "Enter reset code" progression and "Back to sign in" fallback. Nav is gated behind `!isPreLoginView` so auth screens own the viewport.
  - **Preferences persistence**: New `cabal-user-preferences` DynamoDB table (`PAY_PER_REQUEST`, PITR, SSE); `get_preferences` / `set_preferences` Lambdas with claim-scoped reads/writes and strict value validation; IAM + env wiring in `terraform/infra/modules/app`. `useTheme` accepts an `ApiClient`, hydrates once per mount, and debounces persistence at 1 s; localStorage remains the fast path for first render and offline.
  - **Keyboard shortcuts (Interactions §)**: new `useKeyboardShortcuts` hook installs one document `keydown` listener resolving j/k/Enter/e/#/r/a/f/s/u/c/x/Esc/?, ⌘K and `/` for search, and a 1.5 s `g`-prefix chord for `g i` / `g a` / `g s` / `g t` / `g d` folder navigation. `isTypingTarget` skips INPUT/TEXTAREA/contentEditable except for ⌘K. `KeyboardHelp` overlay is a scrim-backed modal with 4 grouped sections (Navigation, Message actions, App, Go to folder).
- **Display serif extended to UI surfaces.** `.folderItem`, `.folderName`, `.addresses-rail__address`, `.envelope-from`, `.msglist-tab`, and the `.reader-sender` / `.reader-sender-name` / `.reader-sender-email` / `.reader-timestamp` / `.reader-to` rules use `var(--font-display)` (Source Serif 4). `:root[data-direction="stately"] body` carries `font-feature-settings: "ss01", "cv11"` to match the mockup.
- **Legacy CSS swept.** `App.css` lost the `*:not(...)` Tahoma/small override, the `button { font-size: x-small !important }` rule, the global `* { border-radius: 0.2em }` + `img { border-radius: 0 }` pair, and the legacy input/button width/margin rules that were forcing the Sort select to 30em and every button to 10em-wide with 1em top margin. `html { -webkit-text-size-adjust: 100% }` preserves mobile-font-boost suppression without the wildcard. Legacy `div.message-list` / `.email_list` `!important` blocks removed from `AppLight.css` / `AppDark.css`.
- **React redesign — Responsive + loading/error state polish**:
  - Mobile-first layout with `@media` guards at 768px (tablet) and 1200px (desktop). Phone collapses to a single pane; tablet runs two panes; desktop keeps the three-pane layout.
  - `Folders` becomes a slide-over drawer under 1200px, triggered by a Nav hamburger via a scoped `CustomEvent`. Selecting a folder or address from the drawer closes any open reader so hamburger → folder returns a fresh list.
  - `Email/MessageOverlay` adopts a sheet posture + floating tab bar (reply / reply-all / forward / archive / trash) on phone; toolbar-row hidden below 768px. Phone reader gains a slim top bar with an `ArrowLeft` Back button wired to the existing `hide()` callback; the label comes from `folderMeta()`.
  - `Email/ComposeOverlay` sheet mode on phone with top chrome (Cancel / New message / Send).
  - Loading states: shimmer skeletons in the msglist (4 fake envelopes) and reader (header + 3 body paragraphs); "Sending…" button label during compose send.
  - Error states: AppMessage red-variant toasts use `--ink-danger`; reader load failures render an inline retry card rather than a disappearing toast.
- **Compose "From" picker** (`Email/ComposeOverlay/FromPicker/`):
  - Trigger renders the selected address + descriptive label with its djb2 swatch and a caret; clicking opens a popover with a search input, a Favorites section, a "More addresses" / "Your addresses" section, a "Type to search N more addresses…" hint when the unfiltered list is capped, and a "No address matches" empty state.
  - Search filters by address, subdomain, and the DynamoDB `comment` field; unfiltered view caps at 12 rows, filtered view at 40. Matching substrings highlighted inline via `<mark class="from-picker__hl">`.
  - Keyboard nav from the search input: ArrowUp/ArrowDown cycle (with wrap), Enter picks the active row, Escape closes. Active row auto-scrolls via `scrollIntoView({ block: 'nearest' })`.
  - Inline "Create a new address" CTA expands the menu into a create form with a back button, a Shuffle "Random" generator, a three-input composer (`username @ subdomain . domain` — domain is a `<select>` of the user's domains), a live preview row, a Note field that maps to DynamoDB `comment`, and validation (regex-gated Create & use button). The domain `<select>` opens on a disabled placeholder so Create & use stays disabled until `username`, `subdomain`, and `domain` are all set.
  - Submit calls `api.newAddress(username, subdomain, tld, comment, address)`, selects the new address on success, fires `onCreated` so `ComposeOverlay` re-fetches the address list (picking up the new row with its note), and writes an `AppMessage` toast — all without closing the compose window.
  - Fresh compose windows start with the picker empty; the user must pick (or create) an address before sending. Reply / reply-all / forward still pre-fill `address` with the original envelope recipient, and a user-picked `composeFromAddress` carries over into the next compose window.
- **Logo asset.** `react/admin/src/assets/logo.svg` carries the smooth circle-with-flag + envelope mark sourced from `apple/handoff/cabalmail-mark.svg`. ViewBox `0 80 400 200` matches the 2:1 brand tile; `fill="currentColor"` carries the Nav / AuthShell light/dark behavior (`--accent` background, `--surface` / `#0b0b0b` foreground).
- **Resizable panes + address-rail polish.**
  - **Three draggable boundaries, all percentage-based.** New `Email/useSplit.js` hook backs three independent splits, each persisted to its own localStorage key and clamped at the JS layer:
    - Folders / Addresses inside the left rail (50% default, 15-85% clamp; rendered in-flow on desktop and inside the drawer on tablet/phone).
    - Folders rail / middle pane (22% default, 15-30% clamp; desktop only — on tablet the rail is a fixed-position drawer).
    - Message list / reader (46% default, 25-65% clamp; tablet+; suppressed on phone where the panes swap rather than share).
  - Each splitter is a 7px hit zone with `role="separator"`, pointer-event drag (`touch-action: none`), keyboard nav (Arrow keys / Home / End / Enter to reset), and double-click reset. The visible 1px line on the leading edge replaces the static `border-right` that used to separate rail from middle and msglist from reader.
  - Widths flow from React state into the DOM as inline `flex-basis` (rail aside, rail panes) and a `--msglist-width` CSS variable consumed by `div.msglist` at the tablet+ media query. Every persisted value is a percentage of its container, so the layout reflows continuously on window resize and crosses the 768/1200 breakpoints without stranding pixel widths.
  - **Address rail polish.**
    - Copy icon (lucide `Copy`) right-aligned on each address row, hover/focus-revealed alongside the existing Revoke action. Click writes the address via `navigator.clipboard.writeText` and toasts via `setMessage`.
    - Comment-on-hover tooltip: rows that have a DynamoDB `comment` set get `data-comment={comment}` and a `::after` bubble below the row (token-styled, `--shadow-menu`, ellipsis at row width, 200 ms hover delay). The native `title=` attribute is suppressed when a comment exists; rows without a comment keep `title=address` as a truncation fallback.
    - Auto-scroll on new-address success: `onRequested` records the new address in a `pendingScroll` state bag; an effect watching `[addresses, pendingScroll]` waits until the refreshed list lands in state, then `querySelector`s the row inside the scoped list ref (`CSS.escape` to handle `@` / `.` / `+` in addresses) and calls `scrollIntoView({ block: 'nearest', behavior: 'smooth' })`.
    - Click-to-filter is a toggle: clicking the active row clears the filter, while clicking any other row sets it as before. Keyboard `Enter` follows the same path.
- **Request modal restyled against the redesign tokens.** `Request.jsx` carries BEM-style `request__*` classes on each input, separator, and button; the submit button is `type="button"`. `Request.css` rewritten end-to-end against the Stately tokens — `--surface` / `--border` / `--ink` inputs with focus ring (`--accent` border + accent-soft 2px box-shadow), accent-fg primary `Request` button matching the rail's "New message" CTA, outlined secondary `Random` / `Clear` buttons, uppercase 11px legends keyed off `--ink-quiet`, and a custom-drawn caret on the domain `<select>`. Selectors are scoped under `.request` so specificity beats the legacy `body button` / `body input` rules without `!important`. The pulsing-while-sending animation is preserved as `request-ripple` on `.request__submit.sending`. Vestigial `.requestVisible` / `.requestHidden` classes (a leftover max-height / padding-top transition pair from when Request was an inline expander) dropped — they could fire on first paint and snap shorter on the first hover-induced reflow, producing a visible "squish" before the form settled at content height.

### Changed

- **Account menu trimmed to match the post-redesign navigation.** The "Folders" top-level view is gone — the folder rail inside the Email view is the only folder surface now — so its menu item is removed from `Nav/`. The "Addresses" menu item is gated behind `isAdmin` since per-user address management lives in the Email view's left rail and the top-level page is the admin-only all-addresses list. `App.jsx` gains a guard that bounces a non-admin away from any admin-only view (persisted in localStorage from a prior admin session or a deep-link) back to "Email". `Folders` is no longer a top-level lazy import in `App.jsx`; it remains imported directly by `Email/index.jsx` for the rail / drawer.
- **`Addresses/index.jsx` split into rail and admin-page components.** The rail (filter, `+ New address`, Request modal) moves to `Addresses/Rail.jsx` and is imported as `AddressesRail` by `Email/index.jsx`. The new `Addresses/index.jsx` is an admin page that loads `listAllAddresses` + `listUsers` and renders every address with its assigned users, per-row user chips (assign / unassign), a New-Address toggle backed by the existing `Request` form, a filter input that searches address / comment / user, and a Revoke button per row. Since the top-level page is now admin-only, it defaults to the all-addresses view rather than reintroducing the old `My Addresses / All Addresses` tab toggle. New `Addresses/Admin.css` namespaced under `.admin-addresses__*`, keyed off the Stately tokens (`--border`, `--surface`, `--ink*`, `--accent`, `--radius-sm`).

## [0.7.0] - 2026-04-27

This release adds an optional monitoring and alerting stack. All components run on the existing ECS cluster and EFS file system. Gated by `var.monitoring` so dev and stage can leave it off; prod always has it on. Push notifications go to the operator's phone via Pushover (priority 1, bypasses Do Not Disturb) and a self-hosted ntfy server, deliberately bypassing Cabalmail's own mail tier so an outage is still reachable.

The full design rationale lives in [`docs/0.7.0/monitoring-plan.md`](docs/0.7.0/monitoring-plan.md). The operator runbook is [`docs/monitoring.md`](docs/monitoring.md).

### Added

#### Alert delivery

- New `terraform/infra/modules/monitoring/` Terraform module gated on `var.monitoring` (per-environment via `TF_VAR_MONITORING`).
- `lambda/api/alert_sink/` -- universal webhook sink fronted by a Lambda Function URL. Authenticates callers with `X-Alert-Secret` (Kuma, Healthchecks) or `Authorization: Bearer` (Alertmanager). Routes by severity: `critical` -> Pushover priority 1 + ntfy priority 5; `warning` -> ntfy priority 3; `info` -> dropped. Translates Alertmanager's native webhook v4 body into the `{severity, summary, source, runbook_url}` shape downstream code expects -- pulls severity/alertname/instance from the first alert's labels, downgrades `status: resolved` to `warning` so recoveries don't re-page on Pushover, and surfaces `runbook_url` annotations as a Pushover tap-action `url` and an ntfy `Click` header. Stdlib only; no boto3 SNS/SES.
- `docker/ntfy/Dockerfile` -- thin wrapper over `binwiederhier/ntfy`. Runs as a `cabal-ntfy` ECS service with EFS-backed cache + auth DB at access point `/ntfy`. Reachable at `https://ntfy.<control-domain>/` with token auth enforced by ntfy itself; the ALB host-header rule for ntfy has no Cognito action.
- Public ALB shared by Kuma, ntfy, Healthchecks, and Grafana. Default action -> Kuma (Cognito). Host-header rules on `ntfy.`, `heartbeat.`, `metrics.` (each with its own Cognito client where applicable).
- VPC private-zone mirrors of the ALB DNS records (`uptime.`, `ntfy.`, `heartbeat.`, `metrics.`, `admin.`) so VPC-internal callers can resolve them; the private zone shadows the public zone for the control domain.
- SSM `SecureString` parameters with `ignore_changes = [value]` so out-of-band rotation sticks: `/cabal/alert_sink_secret` (auto-generated), `/cabal/pushover_user_key`, `/cabal/pushover_app_token`, `/cabal/ntfy_publisher_token`.

#### Uptime monitoring

- `docker/uptime-kuma/Dockerfile` -- thin wrapper over `louislam/uptime-kuma`, running as a `cabal-uptime-kuma` ECS service with EFS-backed SQLite at access point `/uptime-kuma`. The task definition overrides `entryPoint` and runs as UID 1000 to skip the upstream image's `chown -R node:node /app/data`, which fails on EFS access points (access points reject `chown` regardless of caller).
- The eight Kuma monitors are documented in [`docs/monitoring.md`](docs/monitoring.md) step 10: IMAP TLS (993), SMTP relay (25), Submission (587 STARTTLS, 465 implicit), the admin app, an authenticated `/list` round-trip, ntfy health, and a control-domain cert expiry monitor.

#### Heartbeat monitoring

- `docker/healthchecks/Dockerfile` -- thin wrapper over `healthchecks/healthchecks:v3.10`, running as a `cabal-healthchecks` ECS service with EFS-backed SQLite at access point `/healthchecks`. Reachable at `https://heartbeat.<control-domain>/` behind Cognito. Magic-link signup and password-reset mail are delivered through the IMAP tier's local-delivery sendmail (`EMAIL_HOST=imap.cabal.internal:25`, no TLS, no auth) -- Healthchecks emails Cabalmail-hosted addresses inbound to itself, so no Cognito service user, no DKIM, no auth required. Envelope FROM is `noreply@mail-admin.${var.mail_domains[0]}` because the control-domain apex and mail-domain apexes have no MX/A by Cabalmail design and would 553-reject at sendmail's `check_mail` rule. EFS mounts at `/var/local/healthchecks-data` and the container is forced to `user = "1000:1000"` to dodge a separate chown gotcha (the upstream Dockerfile's `mkdir /data && chown hc /data` triggers dockerd copy-up against the access point's posix_user). `ALLOWED_HOSTS=*` because ALB target-group health checks can't set a custom Host header; hostname enforcement is at the ALB layer. New `var.healthchecks_registration_open` (sourced from `TF_VAR_HEALTHCHECKS_REGISTRATION_OPEN`) gates the Healthchecks signup form; the operator flips it on for the bootstrap signup and back off without editing Terraform.
- `lambda/api/healthchecks_iac/` -- Lambda that reconciles Healthchecks check definitions from `config.py` against the running instance via the v3 REST API. Reaches Healthchecks on the private Cloud Map A record (`healthchecks.cabal-monitoring.cabal.internal:8000`), bypassing the Cognito-fronted ALB. Returns `status: skipped` when the API key in `/cabal/healthchecks_api_key` is still placeholder so first apply doesn't fail before bootstrap. Auto-invoked via `aws_lambda_invocation` resource with `lifecycle_scope = "CRUD"` and a trigger on `source_code_hash`, so editing `config.py` re-runs reconciliation on the next apply. Upserts six checks (`certbot-renewal`, `aws-backup`, `dmarc-ingest`, `ecs-reconfigure`, `cognito-user-sync`, `quarterly-review`) and writes their ping URLs into the corresponding `/cabal/healthcheck_ping_*` SSM parameters (only on diff -- no SSM version churn). Logs warnings for checks present in Healthchecks but absent from `config.py`; does not auto-delete.
- `lambda/api/backup_heartbeat/` -- tiny stdlib Lambda invoked by an EventBridge rule on AWS Backup `Backup Job State Change` / `state == COMPLETED` events. Reads its ping URL from SSM, skips silently if the value isn't an HTTP URL, pings via `urllib.request`. The rule fires regardless of `var.backup` -- when the backup plan isn't deployed there are no events to fire.
- Heartbeat instrumentation across five scheduled jobs: `lambda/certbot-renewal/handler.py`, `lambda/api/process_dmarc/function.py`, `lambda/counter/assign_osid/function.py`, and `docker/shared/reconfigure.sh` (the in-container loop in every mail tier) all use the same `HEALTHCHECK_PING_PARAM` env-var -> SSM-fetch -> `urllib`/`curl` ping pattern with a `value.startswith('http')` guard. Consumer modules thread through a `healthcheck_ping_param` (string, default `""`) variable; root `terraform/infra/main.tf` builds the names as locals gated on `var.monitoring`, so flipping monitoring off cleanly drops the env var, the IAM grant, and (for the mail tiers) the ECS `secret` entry. The mail-tier reconfigure heartbeat is injected via a `local.healthcheck_secrets` `concat`-into-secrets pattern in `modules/ecs/task-definitions.tf`.
- New SSM parameters: `/cabal/healthchecks_secret_key` (auto-generated Django secret, rotatable via `terraform taint`), `/cabal/healthchecks_api_key` (operator-seeded after creating in the UI), and six `/cabal/healthcheck_ping_*` placeholders that the IaC Lambda populates after first reconcile.
- New `quarterly-review` Healthchecks check with a 90-day cadence and 14-day grace -- not pinged by automation; the operator pings it manually after walking through the quarterly monitoring review checklist in [`heartbeat-quarterly-review.md`](docs/operations/runbooks/heartbeat-quarterly-review.md).

#### Metrics stack

- `docker/prometheus/`, `docker/alertmanager/`, `docker/grafana/` -- thin wrappers over upstream `prom/prometheus:v3.5.0`, `prom/alertmanager:v0.28.1`, and `grafana/grafana:11.4.0`. Configs and rules are baked in; rebuild + redeploy on change is the upgrade path. Prometheus and Alertmanager have small entrypoint shims that `sed`-substitute runtime placeholders (control domain, environment label, alert_sink Function URL, alert_sink shared secret) into baked-in templates before exec. Grafana ships file-based provisioning for the Prometheus datasource and four bootstrap dashboards (`Mail Tiers`, `AWS Services`, `API Gateway & Lambda`, `Frontend`).
  - Prometheus: 30-day retention; `--web.enable-lifecycle` so reloads are triggerable via `POST /-/reload` from inside the task. EFS access point at `/prometheus` (uid/gid 65534).
  - Alertmanager: silences and notification log at `/alertmanager`. Posts to the alert_sink Lambda with `Authorization: Bearer` from `/cabal/alert_sink_secret` (the Lambda accepts both `X-Alert-Secret` and `Authorization: Bearer`). Critical alerts re-page every 24h on a stuck issue; warnings repeat every 6h. Inhibit rule on `CertExpiringSoonCritical` suppresses the warning variant for the same domain.
  - Grafana: SQLite at `/grafana` (uid/gid 472). Mounts EFS at `/grafana-data` and overrides `GF_PATHS_DATA` to dodge the dockerd copy-up chown gotcha. Provisioned datasource pins `uid: prometheus`; provisioned dashboard JSONs include `"id": null` because Grafana 11.x silently drops dashboards lacking it. Reachable at `https://metrics.<control-domain>/` behind Cognito. Anonymous Cognito-authenticated users land as Viewers; admin actions require the local admin password from `/cabal/grafana_admin_password` (auto-generated `random_password`, `ignore_changes` so rotation sticks).
- `docker/cloudwatch-exporter/`, `docker/blackbox-exporter/`, `docker/node-exporter/` -- wrappers over upstream `prom/cloudwatch-exporter:v0.16.0`, `prom/blackbox-exporter:v0.27.0`, and `prom/node-exporter:v1.9.1`. cloudwatch_exporter scrapes AWS/Lambda, AWS/DynamoDB, AWS/EFS, AWS/ECS, AWS/ApiGateway, AWS/ApplicationELB, AWS/CertificateManager, AWS/Cognito, plus the new `Cabalmail/Logs` namespace; the metric set is intentionally small to keep the GetMetricStatistics call-rate down. The exporter's `CMD` passes `/config/config.yml` positionally (the Java jar's main class takes positional args; the `--config.file=` flag belongs to the Go-based Prometheus binaries and crashes the JVM with `NumberFormatException`). blackbox_exporter ships modules `http_2xx`, `tcp_connect`, `tcp_tls`. node_exporter ships unmodified -- the deviation is in the ECS service that runs it (DAEMON-strategy with host bind-mounts), not the image.
- `node_exporter` runs as a **DAEMON** ECS service (not per-tier sidecars, deviating from the original plan): one task per cluster instance using `network_mode = "host"` with bind-mounts of host `/proc`, `/sys`, and `/` read-only, reporting host-level metrics. DAEMON services use `launch_type = "EC2"` (DAEMON rejects any `capacity_provider_strategy`, even an inherited cluster default), and `service_registries.container_name` / `container_port` must be explicit (ECS can't infer for non-awsvpc tasks). The Cloud Map registration uses an SRV record (host-mode tasks can't register A records).
- `terraform/infra/modules/monitoring/discovery.tf` -- Cloud Map private DNS namespace `cabal-monitoring.cabal.internal` with one service per metrics component plus `healthchecks` (used by the IaC Lambda). Each service definition pins `health_check_custom_config { failure_threshold = 1 }` (the AWS-deprecated value, kept to match server-side defaults) plus `lifecycle { ignore_changes = [health_check_custom_config] }` to prevent a Terraform replacement cycle on every plan. Without this, an empty `health_check_custom_config {}` block reads back as drift on every plan and schedules a forced replacement that fails because the ECS service has live instances registered.
- Cognito user pool client `cabal_metrics_client` for the Grafana ALB rule, mirroring the per-host pattern used for Kuma and Healthchecks.
- ALB listener rule on `metrics.<control-domain>` at priority 120 (after ntfy=100, heartbeat=110), with its own `authenticate-cognito` action.
- New SGs: `cabal-grafana`, `cabal-prometheus` (Grafana-only ingress on 9090), `cabal-alertmanager` (Prometheus + Grafana ingress on 9093), `cabal-monitoring-exporters` (Prometheus-only ingress on 9100-9120), `cabal-healthchecks-iac` (Lambda VPC SG; egress to Healthchecks task on 8000, plus 53/udp for VPC Resolver and 443/tcp for SSM/CloudWatch APIs). All `aws_security_group` and `aws_security_group_rule` descriptions are strict ASCII because the EC2 API rejects Unicode in GroupDescription -- `terraform validate` doesn't catch this; the failure surfaces at apply time.
- 14 initial Prometheus alert rules in [`docker/prometheus/rules/alerts.yml`](docker/prometheus/rules/alerts.yml), grouped:
  - `aws-services`: `Lambda5xxSpike`, `LambdaThrottles`, `LambdaErrors` (regex covers `cabal-.+|assign_osid`), `DynamoDBThrottling`, `DynamoDBSystemErrors`, `EFSBurstCreditsLow`, `ContainerRestartLoop`, `CertExpiringSoonWarning`, `CertExpiringSoonCritical`.
  - `blackbox`: `BlackboxProbeFailure`, `BlackboxTLSCertExpiringSoon`.
  - `platform`: `NodeHighCPU`, `NodeHighMemory`, `NodeDiskSpaceLow`.
  - `log-derived`: `SendmailDeferredSpike`, `SendmailBouncedSpike`, `IMAPAuthFailureSpike` (see below).

  Every rule carries a `runbook_url` annotation pointing into [`docs/operations/runbooks/`](docs/operations/runbooks/). Thresholds match the per-tier "Golden Signals" table in the design doc but are starting points; expect tuning per the per-PR review pattern.
- Prometheus scrape config: `prometheus` (self), `alertmanager`, `cloudwatch` (60s interval to stay under the GetMetricStatistics rate limit), `blackbox-http` (HTTPS to the React app + ntfy `/v1/health`), `blackbox-tcp` (mail-tier ports 993/25/465/587 against `imap.`, `smtp-in.`, `smtp-out.<control-domain>`), and `node` (DNS-SD `type: SRV` against `node-exporter.cabal-monitoring.cabal.internal`). External labels `cluster: cabalmail` and `environment: <prod|stage|dev>` (substituted at boot) so multi-env Grafana dashboards can filter.

#### Log-derived metrics

- Three CloudWatch metric filters per mail-tier log group, defined in [`terraform/infra/modules/monitoring/log_metrics.tf`](terraform/infra/modules/monitoring/log_metrics.tf), emitting to a new `Cabalmail/Logs` namespace. cloudwatch_exporter scrapes them; Prometheus rules in the `log-derived` group alert on the rates.

  | Filter | Pattern | Metric | Alert |
  | --- | --- | --- | --- |
  | `cabal-sendmail-deferred-{tier}` | `"stat=Deferred"` | `SendmailDeferred` | `SendmailDeferredSpike` (warning) |
  | `cabal-sendmail-bounced-{tier}` | `"dsn=5"` | `SendmailBounced` | `SendmailBouncedSpike` (critical) |
  | `cabal-imap-auth-failures` (imap tier only) | `"imap-login" "auth failed"` | `IMAPAuthFailures` | `IMAPAuthFailureSpike` (warning) |

  All filters emit value=1 per matching log line, default 0; CloudWatch aggregates per-minute. The `LambdaErrors` rule's `function_name` regex was extended to `cabal-.+|assign_osid` so the Cognito post-confirmation Lambda is covered without a separate log filter (avoids adopting the Lambda-auto-created `/aws/lambda/assign_osid` log group, which would force a `terraform import` on existing stacks). fail2ban metrics are intentionally not in this set -- `[program:fail2ban]` is currently commented out in every mail-tier `supervisord.conf`; add the filter when fail2ban is re-enabled.
- New `tier_log_group_names` output on the ecs module + variable on the monitoring module so the metric filters reference real log-group resources rather than hardcoded names.
- Decision recorded in [`docs/monitoring.md`](docs/monitoring.md): Cabalmail stays on CloudWatch Logs rather than self-hosting Loki. Log volume is small enough that CloudWatch's per-GB cost is negligible, and adding another stateful ECS service with EFS-backed chunk storage that grows monotonically is more maintenance than the cross-tier search would buy. Revisit if log volume grows past ~10 GB/day or if a recurring incident type needs cross-tier search.

#### Runbooks and tuning discipline

- 18 alert runbooks under [`docs/operations/runbooks/`](docs/operations/runbooks/) plus an index README. Every runbook follows the prescribed shape: what the alert means, who/what is impacted, the first three things to check, and how to escalate.
- The alert_sink Lambda surfaces runbook URLs on outbound pushes:
  - **Prometheus / Alertmanager**: each alert rule carries a `runbook_url` annotation; the Lambda's `_translate_alertmanager` reads it from the first alert's annotations and attaches it to the push.
  - **Kuma / Healthchecks**: their webhook bodies don't carry runbook URLs natively. The Lambda has a static `_RUNBOOK_MAP` keyed by `source` (e.g. `kuma/IMAP TLS handshake`, `healthchecks/certbot-renewal`).

  When a push includes a runbook URL, Pushover renders a "Runbook" tap-action link below the body and ntfy attaches a `Click` header that makes the notification body itself tappable.
- Tabletop exercises documented in `docs/monitoring.md`: simulate mail-queue backup (inject `stat=Deferred` log lines), IMAP cert expiry, certbot Lambda silent disable, and Healthchecks IaC drift; confirm each produces the expected push with a runbook link.

#### Documentation

- [`docs/monitoring.md`](docs/monitoring.md) -- single coherent operator runbook for enabling the stack, completing first-boot configuration, and tuning. Covers Pushover signup, SSM seeding, ntfy admin/token bootstrap, Kuma + Healthchecks first-boot, IaC API key bootstrap, Grafana, Prometheus scrape verification, the runbook framework, tabletop exercises, the quarterly monitoring review, secret rotation, disabling the stack or individual heartbeats, and a consolidated troubleshooting block.
- [`docs/0.7.0/monitoring-plan.md`](docs/0.7.0/monitoring-plan.md) -- design doc with the per-tier "Golden Signals" table, the `var.monitoring` feature-flag pattern, tuning discipline, and Phase-by-phase implementation plan.
- [`docs/0.9.0/state-encryption-plan.md`](docs/0.9.0/state-encryption-plan.md) -- forward-looking plan to migrate both Terraform stacks to client-side KMS-encrypted state (TF 1.10+ `encryption` block) so secrets like the Pushover/ntfy tokens can be folded into normal Terraform inputs instead of seeded out-of-band.

#### CI / build pipeline

- `.github/workflows/docker.yml` matrix gains `prometheus`, `alertmanager`, `grafana`, `cloudwatch-exporter`, `blackbox-exporter`, `node-exporter`, `uptime-kuma`, `ntfy`, `healthchecks`. ECR `extra_repositories` list in `terraform/infra/main.tf` extended in lockstep so the corresponding `cabal-*` repos exist regardless of `var.monitoring` (cheap, not flag-gated).
- `aws Terraform provider >= 6.28.0` is the new floor for the monitoring module (needed for `invoked_via_function_url = true` on `aws_lambda_permission`, which is required for the Lambda Function URL's two-statement resource policy with `authorization_type = NONE`).

### Removed

- `TF_VAR_ON_CALL_PHONE_NUMBERS` and the SMS-via-SNS alerting path. AWS toll-free SMS provisioning was slow and opaque, and SES email can't alert on our own mail outage. Replaced with the Pushover + ntfy push fan-out described above.

### Operational notes

- **Monitoring ALB needs >=2 AZs.** Production has two AZs in `TF_VAR_AVAILABILITY_ZONES`; dev and stage have one each. The per-AZ `cidrsubnet` math in the VPC module makes adding a second AZ to those environments destructive (every subnet is renumbered). The monitoring stack was deployed directly to prod for that reason.
- **Image build must precede first apply that flips `TF_VAR_MONITORING=true`.** The new ECR repos are populated by the next Docker workflow run; if Terraform applies first, the new ECS services sit pending until the `sha-<first-8>` tag exists.
- **SSM seeding is partly manual by design.** Pushover keys and the Healthchecks API key cannot be auto-generated: they come from external accounts (Pushover) or one-time UI actions (Healthchecks). The operator pastes them in once via `aws ssm put-parameter --overwrite`. The placeholder + `ignore_changes` pattern keeps real secrets out of state and out of `terraform.tfvars`. The 0.9.0 plan replaces this once state encryption is in place.
- **ntfy admin password should be short and ASCII.** bcrypt truncates at 72 bytes; non-ASCII or trailing-newline copies fail silently when the mobile app tries to authenticate.
- **GitHub Actions masks `AWS_REGION`** in workflow logs, including the alert_sink Function URL output. The masked URL with literal `***` is unusable; fetch the real URL via `aws lambda get-function-url-config --function-name alert_sink` from a shell with unmasked region.
- **Mail-tier-specific exporters (`dovecot_exporter`, `postfix_exporter`, `opendkim_exporter`) and the `MailQueueGrowing` / `MailDeliveryFailureRate` rules from the original design are not shipped.** `postfix_exporter` parses Postfix log lines; Cabalmail uses Sendmail with a different log format. The CloudWatch metric filter approach (sendmail deferred / bounced rate) covers the same signal without a per-tier sidecar pass and avoids the destructive task-definition replacement that adding sidecars to existing services requires.
- **Kuma config (the eight monitors) stays manual.** Kuma exposes only a Socket.IO API in this release; the unofficial `uptime-kuma-api` library uses an internal message format that has shifted between Kuma minor versions. Building reconciliation around it would couple the Terraform apply path to Kuma's UI implementation. Revisit when Kuma ships a stable REST API ([louislam/uptime-kuma#1170](https://github.com/louislam/uptime-kuma/issues/1170)). Healthchecks IaC works because the v3 REST API is stable.
- **The `_RUNBOOK_MAP` in `alert_sink/function.py` is hand-maintained.** Renaming a Kuma monitor or Healthchecks check without updating the map drops the runbook link from its push. PRs that change one without the other should fail review.
- **Pre-existing Lambda log groups (`/aws/lambda/assign_osid`) are not adopted by Terraform.** Adopting an auto-created log group requires a one-time `terraform import`. Skipped for `assign_osid` -- its errors are caught by extending the `LambdaErrors` rule's regex instead of by a log-derived metric.
- **Lessons surfaced during the deploy and reflected in code** (consolidated as a single troubleshooting section in [`docs/monitoring.md`](docs/monitoring.md)):
  - **EFS access points reject `chown`** regardless of caller. Three workarounds applied: (1) override the upstream `entryPoint` and run as the access point's posix_user (Kuma); (2) mount EFS at a path that doesn't exist in the image so dockerd's copy-up doesn't trigger (Healthchecks at `/var/local/healthchecks-data`, Grafana at `/grafana-data`); (3) force `user = "1000:1000"` on the task definition.
  - **VPC private hosted zone shadows the public zone** for the control domain. Records that exist only in the public zone don't resolve from inside the VPC. The monitoring module mirrors `admin.`, `uptime.`, `ntfy.`, `heartbeat.`, `metrics.` into the private zone so VPC-internal callers can resolve them.
  - **ALB SG needs egress to Cognito** (`0.0.0.0/0:443`) for the `authenticate-cognito` action's code-for-tokens exchange against the Cognito hosted UI domain.
  - **Lambda Function URLs need TWO resource-policy statements** with `authorization_type = NONE`: `lambda:InvokeFunctionUrl` (auth-layer) and `lambda:InvokeFunction` scoped to URL callers via `lambda:InvokedViaFunctionUrl=true` (execute-layer).
  - **Kuma webhook templating is Liquid, not Handlebars.** {% raw %}`{% if ... %}...{% endif %}`{% endraw %} works; {% raw %}`{{#if}}...{{/if}}`{% endraw %} raises `TokenizationError`.
  - **`aws_security_group` and `aws_security_group_rule` GroupDescription is strict-ASCII** at the EC2 API. Non-ASCII characters (em-dash, arrow, section sign, box-draw) trip an `InvalidParameterValue` at apply time. `terraform validate`, `tfsec`, and `checkov` don't catch this. All Terraform `.tf` files in this release are plain ASCII.
  - **CloudWatch metric filters can't carry literal-string dimensions.** The `aws_cloudwatch_log_metric_filter` resource only supports `$<field>` references for dimension values; Cabalmail's metric filters emit dimension-less metrics summed across log groups, with the runbook telling the operator how to identify the offending tier.

## [0.6.4] - 2026-04-23

### Added
- Reader view for HTML message bodies in the Apple clients. A new toolbar toggle in the message detail view swaps between the original author formatting and a reader presentation that overrides CSS with system typography, a capped reading column, and dark-mode support. A new "Default view" picker in Settings → Reading chooses which side of the toggle the detail view opens on; the choice syncs across devices via iCloud alongside the other reading preferences.
- Apple client: the folder message list now refreshes on a 60-second wall-clock timer while it is on screen, in addition to the existing IMAP IDLE push. IDLE usually delivers new mail within seconds, but long-lived IDLE sockets can stall silently — iOS suspends idle connections while the app is foregrounded but network-idle, cellular ↔ WiFi handoffs drop the stream without surfacing an error, and some middleboxes time out TCP idle after a few minutes. The net effect was that users had to pull-to-refresh to see new messages even with the app in the foreground. A second SwiftUI `.task` on `MessageListView` sleeps 60 s and calls `MessageListViewModel.refresh()`; `.task` auto-cancels on `.onDisappear` so the timer starts and stops together with the IDLE watcher and doesn't hold a connection open for a mailbox the user isn't looking at.
- Apple client: the app icon now shows a badge with the Inbox unread count on iOS / iPadOS / visionOS (home-screen icon) and macOS (dock tile). `AppState` owns an independent poller that runs while signed in, requests `.badge` authorization via `UNUserNotificationCenter` on first start (silently no-ops on denial or repeat calls), polls `STATUS (UNSEEN)` on `INBOX` every 60 seconds, and pushes the count through `UNUserNotificationCenter.setBadgeCount(_:)`. The poll is independent of which folder the user is viewing, so the badge stays current even while Drafts/Sent are on screen. Started at the `.signedIn` transition of both `signIn()` and `restoreIfPossible()`; stopped (and the badge cleared) at the start of `signOut()` so the icon doesn't keep showing the previous user's count. Transient network failures leave the prior badge value in place until the next successful poll. The authoritative count is also exposed as an `AppState.inboxUnreadCount` observable for future in-app indicators.

## [0.6.3] - 2026-04-22

### Added

- Apple client: archive/trash button in the message detail toolbar. Matches the list view's swipe action — sets `\Seen` before the `UID MOVE`, prunes the envelope and body caches so a relaunch can't re-hydrate the moved message, and (for users whose dispose preference is Trash) renders as a destructive delete button instead of the archive box. After a successful move the split view advances the envelope selection to the next unread message in the same folder (preferring the next envelope below the disposed one in UID-descending order, falling back to the nearest unread above) and signals the message list to drop the row from its in-memory copy immediately, so the user can keep triaging without bouncing back to the list and doesn't see the archived message linger until the next IDLE refresh. When no other unread messages remain in the folder the selection clears and the detail column falls back to the "No message selected" placeholder. `MessageDetailViewModel.dispose(onSuccess:)` mirrors `MessageListViewModel.dispose(_:)`; `AppState.signalDisposed(folderPath:uid:)` + a new `DisposedEnvelope` payload carry the signal from the detail view's toolbar back to the list view's `.onChange`, which consults `MessageListViewModel.nextUnreadEnvelope(after:)` to pick the advancement target and `MessageListViewModel.pruneEnvelope(uid:)` to drop the disposed row.

### Fixed

- Apple client: `MimeParser.findBlankLine` no longer traps on empty input. The recursive `MimeParser.parse` can be handed an empty `Data` when `splitMultipart` trims a sub-part down to nothing — most reliably reproduced by Microsoft-originated DMARC aggregate reports, whose `multipart/alternative` tree begins with a body-less sub-part. Before the fix, `0..<(bytes.count - 1)` became `0..<-1` and tripped Swift's `Range requires lowerBound <= upperBound` runtime check (`EXC_BREAKPOINT` / `SIGTRAP`), crashing the detail view the moment a DMARC report was opened on both iOS and macOS. Now guarded with `bytes.count >= 2`; regression coverage in `MimeParserTests.testMultipartWithEmptyLeadingSubPartDoesNotCrash`.
- Apple client: remote content in HTML messages is now genuinely blocked when the `Load remote content` preference is Off or Ask, fixing the regression where tracker pixels and remote images were fetching despite the toolbar "eye" icon showing the closed state. `HTMLBodyView`'s `WKNavigationDelegate.webView(_:decidePolicyFor:)` only intercepts top-level and subframe navigations; subresource loads (images, CSS, fonts, iframes — the tracker-pixel vector) bypass the delegate entirely, so the "deny non-file URLs in `decidePolicyFor`" approach never actually blocked them. The renderer now installs a `WKContentRuleList` that blocks every `http`/`https` request on the web view's `userContentController` when `allowRemote` is false, and removes it when the user flips the toolbar toggle. The rule list is compiled once per process and cached. The navigation-delegate check stays in place as a secondary guard against top-level navigations (meta-refresh, document.location=…) the user didn't ask for.
- Bump `actions/checkout`, `actions/cache`, `actions/upload-artifact`, and `actions/download-artifact` to v5 across all workflows, ahead of GitHub's Node.js 20 deprecation (forced to Node 24 on 2026-06-02, removed 2026-09-16). Also pins the two lambda workflows that were tracking `actions/checkout@main` to a fixed tag.

## [0.6.2] - 2026-04-22

### Fixed

- Apple client: the folder message list now fetches the top page by IMAP sequence number (`FETCH (messages - pageSize + 1):*`) instead of a UID range window (`UID FETCH (UIDNEXT - pageSize):UIDNEXT`). The UID-range approach silently returned fewer envelopes than requested whenever UIDs were sparse after expunges — a long-lived Inbox with UIDNEXT well past pageSize but only a handful of surviving messages would render just the few whose UIDs happened to land in the top-pageSize band (observed as "Inbox shows only 3 of 19 messages"). Dense folders (hundreds of thousands of messages) were unaffected because their UIDs are contiguous. `loadMoreIfNeeded` continues to paginate older pages by UID. New `ImapClient.topEnvelopes(folder:limit:totalMessages:)` protocol method, regression coverage in `ImapClientTests`.

## [0.6.1] - 2026-04-21

### Fixed

- Apple client: IMAP envelope subject and address display names now pass through `HeaderDecoder.decode`, so RFC 2047 encoded-words (`=?utf-8?B?…?=`, `=?utf-8?Q?…?=`) render as their decoded text instead of appearing literally. Matches the Python `decode_header` behavior in `lambda/api/list_envelopes/function.py`. Regression coverage added in `ImapParserTests`.

## [0.6.0] - 2026-04-20

### Added

- `apple/` — Phase 1 scaffolding for the native Apple client (iOS/iPadOS/visionOS app target + native macOS app target + shared `CabalmailKit` Swift package with `Configuration` model and smoke tests)
- `apple/project.yml` — XcodeGen spec; the `.xcodeproj` is generated at build time rather than committed
- `apple/Local.xcconfig.example` — template for a gitignored per-developer xcconfig supplying `DEVELOPMENT_TEAM`
- `.github/workflows/apple.yml` — Phase 2 CI/CD for the Apple client: `kit-test` (SwiftLint + CabalmailKit tests across macOS/iOS/visionOS), `app-build` (unsigned build of both app targets), `upload-ios` (archive + TestFlight upload, main/stage only), `upload-mac` (archive + TestFlight upload + developer-id notarization + workflow artifact, main/stage only)
- `apple/.swiftlint.yml` — permissive SwiftLint configuration tuned for the current scaffold
- `apple/ci/ExportOptions-iOS.plist`, `apple/ci/ExportOptions-macOS.plist`, `apple/ci/ExportOptions-macOS-DeveloperID.plist` — archive export configurations used by the upload jobs
- `apple/scripts/generate-placeholder-icons.sh` + `generate-placeholder-icon.swift` — one-shot generator for a 1024×1024 placeholder app icon (rendered via CGContext for exact pixel dimensions) and sips-derived macOS icon catalog sizes. Replace output with real artwork before non-internal distribution
- `CFBundleIconName: AppIcon` and `ITSAppUsesNonExemptEncryption: false` set on both app targets via `project.yml` — required by App Store validation for icon-catalog apps and pre-answers the TestFlight export-compliance prompt for HTTPS-only traffic
- Terraform: `aws_s3_object.website_config_json` in `terraform/infra/modules/app/s3.tf` — publishes `/config.json` alongside `/config.js` so the Apple client has a parseable runtime configuration source
- Documentation: Phase 1 decisions recorded in `apple/README.md` (native macOS target over Mac Catalyst; `config.json` delivery over bundled `.xcconfig`); Phase 2 CI layout and required GitHub secrets documented in the same file
- **Apple client Phase 3 — Authentication & Transport** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.AuthService` protocol + `CognitoAuthService` actor — hand-rolled Cognito `USER_PASSWORD_AUTH` / `REFRESH_TOKEN_AUTH` over `URLSession`, plus sign-up, confirm, forgot-password, resend flows. Matches the pool's `explicit_auth_flows = ["USER_PASSWORD_AUTH"]` so no AWS Amplify dependency is required.
  - `CabalmailKit.SecureStore` protocol with a Security-framework-backed `KeychainSecureStore` (data-protection keychain, shared iOS/macOS) and an `InMemorySecureStore` for tests. Tokens persist as a single JSON blob; IMAP username/password live in separate keychain items so sign-out clears them alongside the tokens.
  - `CabalmailKit.ApiClient` protocol + `URLSessionApiClient` actor — attaches the Cognito ID token to every request, transparently retries once on 401 after forcing a refresh, and surfaces a second 401 as `.authExpired`. Backs `/list`, `/new`, `/revoke`, and `/fetch_bimi`.
  - `CabalmailKit.ImapClient` protocol + `LiveImapClient` actor — TLS-from-connect IMAPS (993) via a `NetworkByteStream` built on `NWConnection`. Supports LOGIN, LIST/LSUB with `/`↔`.` delimiter translation, CREATE/DELETE/SUBSCRIBE/UNSUBSCRIBE, STATUS, SELECT, UID FETCH (ENVELOPE/FLAGS/BODYSTRUCTURE/RFC822.SIZE/INTERNALDATE/BODY[]), UID STORE, UID MOVE (with COPY+STORE+EXPUNGE fallback for servers without RFC 6851), UID SEARCH, APPEND, LOGOUT, and IDLE (via a dedicated second connection yielding an `AsyncThrowingStream<IdleEvent, Error>`).
  - `CabalmailKit.SmtpClient` protocol + `LiveSmtpClient` actor — submission over implicit TLS on port 465 (the submission listener in `terraform/infra/modules/elb/main.tf` binds both 587 and 465; 465 sidesteps `NWConnection`'s lack of STARTTLS upgrade support). AUTH PLAIN against the same Cognito credentials Dovecot uses, RFC 5322 message assembly via `MessageBuilder` (multipart/alternative, multipart/mixed with attachments, RFC 2047 header encoding, RFC 2045 base64 wrapping, RFC 5321 dot-stuffing).
  - `CabalmailKit.EnvelopeCache` — per-folder JSON snapshot keyed by UIDVALIDITY, sized for the "STATUS + UID FETCH since UIDNEXT" reconnect flow from the plan.
  - `CabalmailKit.MessageBodyCache` — disk-backed LRU for `BODY.PEEK[]` payloads with a configurable byte cap (default 200 MB), evicting by file mtime.
  - `CabalmailKit.AddressCache` — in-memory actor mirroring the React app's `localStorage[ADDRESS_LIST]` invalidation pattern.
  - `CabalmailClient` actor rebuilt as the top-level facade: owns the auth session and exposes every service + cache; `CabalmailClient.make(configuration:secureStore:...)` wires production against the real Cognito/API/IMAP/SMTP tiers in one call.
  - `CabalmailKit` test target coverage for: Cognito sign-in happy path and refresh-on-expired, `NotAuthorizedException` mapping, `ApiClient` token attachment and 401→refresh→retry behavior, IMAP LIST/STATUS/FETCH-with-literal/STORE/MOVE-with-fallback + folder-delimiter translation, SMTP AUTH-failure mapping and dot-stuffing, and the IMAP response parser across tagged/untagged/FETCH/SEARCH shapes.
- **Apple client Phase 4 — Mail Reading** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.ConfigLoader` — fetches `/config.json` from a user-supplied control domain. The sign-in form passes the domain once; subsequent launches reuse the cached `Configuration` so the same binary works against dev/stage/prod.
  - `CabalmailKit.MimeParser` — hand-rolled multipart tree walk over raw `BODY.PEEK[]` bytes. Decodes RFC 2045 `Content-Type` / `Content-Disposition` / `Content-Transfer-Encoding` parameters, traverses arbitrarily-nested `multipart/*`, and exposes leaf parts, attachment candidates, and a `cid:` → decoded-body map for inline images.
  - `CabalmailKit.MimeDecoders` — quoted-printable and base64 body decoders; lenient on malformed input so one broken part doesn't blank the whole message.
  - `CabalmailKit.HeaderDecoder` — RFC 2047 encoded-word decoder (UTF-8 / ISO-8859-1 / Windows-1252 / US-ASCII; Q and B), including the §6.2 rule that whitespace between adjacent encoded-words is stripped.
  - 9 new `MimeParserTests` cover plain text, base64 bodies, quoted-printable with soft-break and hex escapes, `multipart/alternative`, `multipart/mixed` with attachments, encoded-word headers, mixed-encoding header values, and folded-header unfolding. Total `CabalmailKit` tests: 39 (was 30).
  - App target (`apple/Cabalmail/`): `AppState` (`@Observable @MainActor`) as the root state; `SignInView` (control domain + user/pass); `FolderListView` with per-folder `STATUS (UNSEEN)` badges, Inbox-pinned-first ordering, and pull-to-refresh; `MessageListView` with UIDNEXT-based sliding-window fetch, on-scroll pagination, `.searchable` wired to IMAP `UID SEARCH`, swipe-to-archive / swipe-to-flag; `MessageDetailView` with headers block, body renderer, attachment strip, and a toolbar "Load remote content" toggle; `HTMLBodyView` wrapping `WKWebView` with non-persistent data store, JS disabled, and a `WKNavigationDelegate` that rejects every non-`file://` / non-`data:` request unless the user has flipped the toggle; `AttachmentStrip` opens downloads via `QLPreviewController` on iOS / visionOS and `NSWorkspace.open(_:)` on macOS.
  - `MailRootView` branches on horizontal size class: iPhone gets a `NavigationStack` (folder → messages → detail), iPad / macOS / visionOS get a three-column `NavigationSplitView`.
  - macOS target (`apple/CabalmailMac/`): now shares the iOS view sources via `project.yml` (`Cabalmail/ContentView.swift`, `Cabalmail/AppState.swift`, `Cabalmail/Views/`, `Cabalmail/ViewModels/`). The Phase 1 "separate views per target" decision relaxed to "shared SwiftUI, separate bundles + entry points"; the Settings scene and hardened-runtime entitlement stay macOS-only.
  - Root envelope-list cache integration: `MessageListViewModel` hydrates from `EnvelopeCache` on open (so reopen is instant), merges refreshed envelopes back, and invalidates both caches on a `UIDVALIDITY` change. `MessageDetailViewModel` consults `MessageBodyCache` before issuing `UID FETCH BODY.PEEK[]`.
- **Apple CI hardening — manual code signing for archive + export:**
  - Both `upload-ios` and `upload-mac` archive steps now sign manually (`CODE_SIGN_STYLE=Manual`, `PROVISIONING_PROFILE_SPECIFIER=<UUID>`, `CODE_SIGN_IDENTITY="Apple Distribution"`) against a provisioning profile installed from a new per-target GitHub secret. `-allowProvisioningUpdates` and the `-authenticationKey*` args are dropped from `xcodebuild archive` and `exportArchive`; auto-provisioning never touches Development certs, so Apple's per-team cert cap no longer fails the build.
  - New composite action `.github/actions/install-provisioning-profile` decodes a base64-encoded profile (iOS `.mobileprovision` or macOS `.provisionprofile`) into `~/Library/MobileDevice/Provisioning Profiles/`, reads the UUID from the CMS-signed plist, and exports it via `$GITHUB_ENV` so the archive step can reference it as `PROVISIONING_PROFILE_SPECIFIER`.
  - Export-options plists are now generated at CI time via heredoc with the profile UUID embedded in `provisioningProfiles`; the static `apple/ci/ExportOptions-*.plist` files are removed. Removes the risk of archive-vs-export profile drift.
  - Mac App Store `.pkg` signing: the `upload-mac` job now imports a **Mac Installer Distribution** cert alongside the Apple Distribution cert (the outer `.pkg` wrapper needs its own cert), and the generated export-options plist references it via `installerSigningCertificate = "3rd Party Mac Developer Installer"`. New required secrets: `MAC_INSTALLER_CERT_P12` / `MAC_INSTALLER_CERT_PASSWORD`. The keychain password is now persisted to `$RUNNER_TEMP/keychain-password` (chmod 600) so the optional Developer ID import later in the same job can unlock the same keychain.
  - `CURRENT_PROJECT_VERSION` is now a Unix timestamp (`date -u +%s`) rather than `github.run_number`. `CFBundleVersion` must be strictly monotonic per marketing version across everything that has ever uploaded to the App Store Connect record, and `run_number` can drift below the highest previously-uploaded build (e.g. after a workflow rename). Timestamps are always higher than the last upload.
  - New required secrets: `IOS_APP_STORE_PROFILE` (gates `upload-ios`), `MAC_APP_STORE_PROFILE` + `MAC_INSTALLER_CERT_P12` + `MAC_INSTALLER_CERT_PASSWORD` (gate `upload-mac`), and optionally `MAC_DEVID_PROFILE` (paired with `DEVELOPER_ID_CERT_P12` to produce the notarized direct-distribution artifact; missing either pair member skips that artifact cleanly).
  - App Store Connect API key role can drop from **Admin** to **App Manager** — CI no longer calls the profile-creation API. Documented in `apple/README.md`.
- **Apple client Phase 5 — Mail Composition & On-the-Fly From** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.ReplyBuilder` — pure value-type helper that turns an `Envelope` + its decoded plain-text body + the user's owned addresses into a seeded `Draft`. Implements idempotent `Re:` / `Fwd:` subject prefixing, `In-Reply-To` / `References` threading, reply-all deduplication and self-exclusion, reply-attribution + `>`-prefixed quoting, forward-banner quoting, and the "default From to the original's addressee" rule that makes the per-correspondent address minted for one reply reusable across the whole thread.
  - `CabalmailKit.Draft` + `CabalmailKit.DraftStore` — Codable model and atomic on-disk store (`{cacheDirectory}/drafts/{uuid}.json`) with corrupt-file recovery. `ComposeViewModel` autosaves every 5 s while the sheet is open so a mid-compose app kill is recoverable.
  - `CabalmailClient.send(_:)` facade — stamps a shared `Message-ID`, submits the payload via SMTP, then best-effort-`APPEND`s the identical payload to the `Sent` IMAP folder with `\Seen` set. Matches the React app's `send` Lambda behavior so both clients produce the same Sent-folder view; a failed APPEND after a successful submission does not surface as a send error.
  - `OutgoingMessage.messageId` — optional, lets the sender supply a pre-generated Message-ID so the Sent copy and the wire copy thread as one message.
  - App target: `Cabalmail/Views/ComposeView.swift` (SwiftUI form sheet — From picker, To/Cc/Bcc token fields, Subject, plain-text `TextEditor`, attachment strip, Cancel/Attach/Send toolbar, discard-draft confirmation); `Cabalmail/Views/FromPicker.swift` (Menu with "**Create new address…**" as the first, always-visible item per the Cabalmail on-the-fly-From idiom, alphabetized existing addresses below); `Cabalmail/Views/NewAddressSheet.swift` (inline address-creation form mirroring `react/admin/src/Addresses/Request.jsx`, including the Random button); `Cabalmail/ViewModels/ComposeViewModel.swift` (state, autosave loop, send/cancel/discard flows, `canSend` gating, PhotosPicker + fileImporter ingestion).
  - `MessageDetailView` gains a Reply / Reply All / Forward menu in its toolbar; `MessageListView` gains a New Message toolbar button. Both present the same `ComposeView` sheet, differentiated only by the `Draft` seed passed in (`ReplyBuilder.build(from:body:mode:userAddresses:)` vs `ReplyBuilder.newDraft()`).
  - `MailRootView` seeds `selectedFolder` to INBOX the first time the folder list loads, so a freshly-signed-in user lands in a state where the New Message button on the message-list toolbar is reachable instead of on an empty "Select a folder" screen.
  - `URLSessionApiClient.listAddresses()` decodes the real `/list` Lambda wire shape (`{"Items": [...]}`, mirroring the DynamoDB scan response), with the previous `{"addresses": [...]}` and bare-array fallbacks kept as lenient alternates. Pinned with a test against the exact Lambda output so the compose From picker can't silently fail to decode again.
  - `CabalmailKit` test coverage: 12 `ReplyBuilderTests` (subject prefixing idempotence, default-From selection from owned addresses including case-insensitive match and "no owned match → nil" fallthrough, reply-to-list primary/cc split, reply-all dedup + self-exclusion, Reply-To-over-From precedence, forward-has-no-recipients, reply-body `>` quoting + attribution line, forward banner, threading-headers with and without the original's In-Reply-To, ReplyBuilder → OutgoingMessage → MessageBuilder integration asserting the wire payload includes the right `In-Reply-To` / `References` / `Re:` subject); 8 `DraftStoreTests` (round-trip, empty-draft-not-persisted, empty-draft-cleans-stale-file, list-sorted-newest-first, remove, corrupt-file-skipped-and-removed, load-missing-returns-nil, save-replaces-existing); 1 new `ApiClientTests.testListAddressesDecodesItemsWrapperFromLambda` pinning the `/list` wire shape.
  - `CabalmailClient` stored properties marked `nonisolated` (immutable, `Sendable`) so SwiftUI views can read `client.configuration.domains` and other references synchronously — mutating flows still funnel through the actor's methods.
  - `ImapClient.swift` split into three files to stay under SwiftLint's 400-line cap and keep the public protocol separate from the actor: `ImapClient.swift` (public protocol + `IdleEvent` + connection-factory types), `LiveImapClient.swift` (actor + IMAP commands + transport-retry + internals extension), and `LiveImapClient+Idle.swift` (public IDLE extension). Behavior unchanged; `LiveImapClient.move(_:)` hoists the quoted destination string into a local to stay under the 120-col line-length cap.
- **Apple client Phase 6 — Address & Folder Management** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.Preferences` — `@Observable @MainActor` preferences object covering the five Phase 6 surfaces (Reading: `MarkAsReadBehavior` + `LoadRemoteContentPolicy`; Composing: default From address + plain-text signature; Actions: `DisposeAction`; Appearance: `AppTheme`). Backed by a pluggable `PreferenceStore` protocol. `UbiquitousPreferenceStore` persists locally to `UserDefaults` and syncs across devices via `NSUbiquitousKeyValueStore`, mirroring every change both ways; `InMemoryPreferenceStore` backs tests and SwiftUI previews. An `isReloading` guard keeps an incoming iCloud push from re-persisting through the property `didSet` hooks.
  - `CabalmailKit.SignatureFormatter` — pure value-type helper that inserts the signature into a compose body with the RFC 3676 `-- ` delimiter on its own line. Handles the three entry points (empty new message / reply-or-forward with a leading blank-line-attribution-quoted-original base / arbitrary base) so compose always lands with the user's signature in the expected position.
  - App target: `Cabalmail/Views/AddressesView.swift` (my-addresses list with revoke-via-swipe + context menu + confirmation dialog; "+" toolbar presents the same `NewAddressSheet` the compose From picker uses, so address creation is identical between the two entry points); `Cabalmail/Views/FoldersAdminView.swift` (subscribed / not-subscribed sections, per-row subscription toggle, swipe-to-delete on user folders with confirmation, system folders protected from delete; "+" toolbar opens a `NewFolderSheet` with an optional parent picker seeded from the current folder list); `Cabalmail/Views/SettingsView.swift` (Account, Reading, Composing, Actions, Appearance, About sections mapped to the plan's preference table); `Cabalmail/Views/SignedInRootView.swift` (`TabView(selection:)` + `Tab { … }` with `.sidebarAdaptable` style — iPhone gets a bottom tab bar, iPad/visionOS/macOS get a sidebar; macOS hides the Settings tab because the Settings scene at ⌘, handles it); `Cabalmail/ViewModels/AddressesViewModel.swift` + `Cabalmail/ViewModels/FoldersAdminViewModel.swift` (wrap `CabalmailClient.addresses` / `revokeAddress` and the IMAP LIST / CREATE / DELETE / SUBSCRIBE / UNSUBSCRIBE commands with list state and error banners).
  - `MessageListViewModel.dispose(_:)` now reads `Preferences.disposeAction` at call time — Archive or Trash — instead of hardcoding Archive; `MessageListView`'s trailing swipe label and icon follow the preference in real time. `MessageDetailViewModel` honors the three mark-as-read modes: `.manual` is a no-op (Phase 4 default), `.onOpen` sets `\Seen` the moment the body loads, and `.afterDelay` schedules a cancellable 2-second task that the detail view cancels on disappear so a message the user only previewed for a moment stays unread. `MessageDetailViewModel` also seeds `remoteContentAllowed` from `Preferences.loadRemoteContent` (`.off` / `.ask` start blocked, `.always` opens the gate).
  - `ComposeViewModel` gains a `Preferences` parameter; `fromAddress` defaults to `Preferences.defaultFromAddress` only when the seed didn't already pick one (so the reply-builder "default From to the original's addressee" rule from Phase 5 still wins on replies), and the body is seeded through `SignatureFormatter.seedBody` so a configured signature lands in the right place for new messages, replies, and forwards.
  - `CabalmailApp` / `CabalmailMacApp` now own the `AppState` and `Preferences` instances at the App level (previously the iOS target's `ContentView` owned an inline `@State AppState`). Hoisting them lets the macOS `Settings` scene bind the same `Preferences` instance the main window uses, and gives both targets a single place to wire `.preferredColorScheme` off the theme preference so Theme = Dark flips the whole app immediately without a round-trip through the mail views. The `FolderListView` toolbar's sign-out button is removed — Settings is the canonical place for account controls now.
  - `CabalmailKit` test coverage: 9 `PreferencesTests` (defaults match the plan; every preference persists through the store; nil-assignment removes the key; initial values are read from a populated store on init; garbage raw values fall back to the enum default; external changes refresh every property; external reload doesn't re-persist through `didSet`; DisposeAction → IMAP folder name mapping); 5 `SignatureFormatterTests` (empty signature is a no-op; empty base lands signature below a blank line; reply base inserts signature above the quoted block; arbitrary base prefixes signature with a line break; multi-line signatures preserved).
- **Apple client Phase 6 follow-ups** (`docs/0.6.0/ios-client-plan.md`, TestFlight feedback):
  - **Archive marks as read, matching the React webmail.** `MessageListViewModel.dispose(_:)` now sets `\Seen` on the message before the `UID MOVE` (after the move the UID is no longer in the current folder, so STORE would be rejected). A failed mark-read short-circuits the move the same way a failed move short-circuits the cache prune.
  - **Dispose and refresh now prune the envelope + body caches, fixing "archived messages reappear after relaunch."** `EnvelopeCache` gains `remove(uids:folder:)` and `replace(envelopes:uidValidity:uidNext:keepingRange:into:)`; the former drops specific UIDs from a folder's snapshot, the latter rewrites the refresh-window portion of the cache so any cached UID the server didn't return in the fetch response is pruned (outside-window older pages are preserved). `MessageBodyCache` gains a per-UID `remove(folder:uidValidity:uid:)`. `dispose(_:)` calls both after a successful move; `refresh()` computes the set of UIDs in the refresh window that the server no longer returns and prunes them from both the in-memory array and the persistent cache.
  - **Re-entrant-dispose guard against the UIKit assertion crash.** Previously, rapid-fire swipe-archive on several rows fired overlapping `Task { await model.dispose(...) }` invocations, each of which mutated `envelopes` on completion. The resulting SwiftUI diffs during an in-flight layout could trip `NSInternalInconsistencyException` from UIKit's CollectionView diffing path (observed in a TestFlight crash report). `MessageListViewModel` now tracks `pendingDisposeUIDs: Set<UInt32>` and short-circuits a second dispose for a UID while the first is in flight; `loadMoreIfNeeded` additionally defers pagination while any dispose is pending and stops spinning when an empty fetch returns (instead of decrementing `lowestUID` one at a time until it reaches the bottom).
  - **Swipe direction swap to match Mail.app conventions.** Leading (left-to-right) swipe now toggles `\Seen` (Mark as Read / Mark as Unread, `envelope.open` / `envelope.badge` icons); trailing (right-to-left) stays Archive/Trash per the Dispose preference. Flag is still reachable via the row's context menu, which also exposes Mark-as-Read and Dispose for pointer-only callers (Mac / iPad with trackpad).
  - **Launch auto-restore via Keychain-persisted Cognito tokens.** `AppState` adds a `.restoring` status and a `restoreIfPossible()` method that, on launch, reads `controlDomain` + `lastUsername` from `UserDefaults` and the Cognito tokens from the Keychain, loads `Configuration` from the control domain, constructs a `CabalmailClient`, and calls `authService.currentIdToken()` to force a silent refresh (cached token → no-op; expired ID token → refresh via stored refresh token; revoked refresh token → `invalidCredentials`). On success the app transitions straight to `.signedIn` and skips the sign-in form. On `authExpired` / `invalidCredentials` / `notSignedIn` the keychain is wiped so the form starts clean (username / control domain stay pre-filled). On transient network errors (airplane mode at launch) the keychain is preserved so a later retry can recover without forcing a password re-entry. `CabalmailApp` and `CabalmailMacApp` wire `await appState.restoreIfPossible()` via `.task` at the root scene; `ContentView` branches on `.restoring` to show a neutral splash rather than flashing the sign-in form for a frame.
  - `CabalmailKit` test additions: 6 `EnvelopeCacheTests` (remove-drops-UIDs, remove-no-op-for-unknown, remove-no-op-without-snapshot, replace-prunes-missing-UIDs-inside-range, replace-with-nil-range-replaces-everything, replace-clears-old-on-UIDValidity-mismatch). Total `CabalmailKit` tests: 88 (was 82). The AppState restore branching is covered indirectly by the existing `AuthServiceTests` pins of `currentIdToken()` refresh success, `NotAuthorizedException` → `invalidCredentials`, and `signIn` keychain persistence.

### Changed

- **Let's Encrypt production CA in every environment.** `lambda/certbot-renewal/handler.py` no longer branches on `USE_STAGING`, and the `certbot_renewal` Terraform module drops its `prod` input variable. Staging certs (previously used for non-prod environments) aren't trusted by iOS/macOS root stores, so an Apple client hitting `smtp-out.<control_domain>` on port 465 (TCP passthrough, Dovecot presents the Let's Encrypt cert directly) couldn't complete the implicit-TLS handshake. The certbot Lambda re-issues against production on its next run; force a manual invocation after deploy if you want the swap immediately rather than on the scheduled renewal.
- **Certbot Lambda `image_uri` rotates per deploy.** The module had `image_uri = "${repo_url}:latest"` hardcoded, which Terraform treats as a string that never changes — the Lambda kept running whichever image had been pushed the first time it was created, even when CI pushed a new `:latest` tag. The module now takes an `image_tag` input wired from `/cabal/deployed_image_tag` (the same SSM parameter the ECS task definitions consume), so the Lambda's image reference rotates on every deploy.

## [0.5.0] - 2026-04-20

### Known Issues

- Forgot Password and Verify Phone were delivered untested due to delays in provisioning an SMS number in AWS

### Added

- **Admin dashboard with user management (Phase 1 of `docs/0.5.0/user-management-plan.md`):**
  - Cognito admin group (`aws_cognito_user_group "admin"`) with master user placed in it via `aws_cognito_user_in_group`
  - 5 new admin-only Lambda functions: `list_users`, `confirm_user`, `disable_user`, `enable_user`, `delete_user`
  - Lambda IAM policy extended with Cognito permissions (`ListUsers`, `AdminConfirmSignUp`, `AdminDisableUser`, `AdminEnableUser`, `AdminDeleteUser`) scoped to the user pool ARN
  - `USER_POOL_ID` env var added to all Lambda functions
  - `ApiClient` methods: `listUsers`, `confirmUser`, `disableUser`, `enableUser`, `deleteUser`
  - React `Users` tab — lists pending and confirmed users with Confirm/Disable/Enable/Delete actions; visible only to members of the admin group (detected via the `cognito:groups` JWT claim)
  - React `Dmarc` tab placeholder (wired into routing for Phase 3)
  - Admin-gated nav visibility via `is-admin` CSS class
  - Self-deletion guard in `delete_user`
  - Master system account filtered from the Users view so it cannot be modified
- **DMARC report ingestion and display (Phase 3 of `docs/0.5.0/user-management-plan.md`):**
  - `dmarc` system Cognito user (osid=9998) with a dedicated mailbox, address `dmarc-reports@mail-admin.<first-mail-domain>` created in `cabal-addresses`, and DNS records for the `mail-admin` subdomain (MX/SPF/DKIM/DMARC CNAMEs)
  - Global DMARC DNS record updated to use the configured mail domain instead of a hardcoded value
  - DynamoDB table `cabal-dmarc-reports` (composite key: `header_from#date_end` / `source_ip#report_id`, PITR, server-side encryption)
  - `process_dmarc` Lambda (Python 3.13, arm64, 512MB, 120s) — authenticates to IMAP via the master-user pattern (`dmarc*admin`), fetches the `dmarc` inbox, parses zip/gzip/raw XML DMARC aggregate reports (RFC 7489), writes records to DynamoDB in batches, then moves processed messages to `INBOX.Processed`
  - Handles RFC 2047 encoded-word attachment filenames and `application/octet-stream` attachments from mail clients that don't set specific MIME types
  - EventBridge Scheduler triggers `process_dmarc` every 6 hours with a flexible 30-minute window
  - `list_dmarc_reports` admin-only Lambda — paginated DynamoDB scan with base64-encoded `next_token`
  - `ApiClient.listDmarcReports(nextToken)` method
  - React `Dmarc` tab — full implementation with org/domain/source IP/count/disposition/DKIM/SPF columns, color-coded pass/fail badges, refresh button, and "Load more" pagination
  - `dmarc` system user filtered from the Users admin view (same pattern as `master`)
- Mobile hamburger menu — below 959px (covers portrait and landscape phones) the nav tabs collapse into a hamburger dropdown so admin tabs like DMARC stay reachable on narrow screens
- **Multi-user address management (Phase 4 of `docs/0.5.0/user-management-plan.md`):**
  - Surfaces the latent multi-user delivery already supported by `docker/shared/generate-config.sh` (slash-separated `user` field expanded via `/etc/aliases.dynamic`)
  - 4 new admin-only Lambda functions: `assign_address` (PUT), `unassign_address` (PUT), `new_address_admin` (POST), `list_addresses_admin` (GET)
  - Cognito `AdminGetUser` added to the shared Lambda IAM policy so admin endpoints can validate that target users exist before writing
  - `assign_address`/`unassign_address`/`new_address_admin` all publish to the existing address-change SNS topic to trigger container reconfiguration, matching the `new`/`revoke` pattern
  - `unassign_address` refuses to remove the last user from an address (use `revoke` to delete instead)
  - `ApiClient` methods: `listAllAddresses`, `assignAddress`, `unassignAddress`, `newAddressAdmin`
  - Admin-only "All Addresses" tab in the Addresses view (`Addresses/Admin.jsx`) — filter/search, New Address form with multi-user assignment checkboxes, per-row chips showing assigned users with inline × removal, and a "+ User" picker to assign additional users
  - Confirmed users in the Users tab now display their assigned addresses as chips, with inline × removal on shared addresses and a "+ Address" picker to assign existing addresses to a user
  - Hover/tap on a shared-address chip in the Users tab highlights identical chips under other users (tap toggles a sticky highlight on touch devices)
  - `master` and `dmarc` system users excluded from the admin Assign-to picker

### Fixed

- `SignUp` form inputs were uncontrolled — App.jsx now passes `username`, `password`, and `phone` props so typing is reflected in the SignUp form instead of leaking into Login's shared state
- Stale per-user cache after logout — `ADDRESS_LIST`, `FOLDER_LIST`, and `INBOX` localStorage keys are now cleared in `doLogout`, preventing the next user from seeing the previous user's folders and addresses
- DMARC report list couldn't be scrolled when long because `Email.css` globally sets `body` to `position: absolute; overflow: hidden`; scoped `overflow: auto` and `max-height` to `div.App div.Dmarc` so it scrolls independently
- Nav dropdown was hidden on the Email tab because `div.email_list` has `z-index: 99999`; raised the nav's `z-index` to `100000` so the hamburger menu stays above view-level overlays
- `lambda/api/list` filter was an exact match on the `user` field, so callers who were one of several users on a multi-user address lost it from their "My Addresses" view — switched to a `contains()` DynamoDB scan filter plus a Python slash-split membership check (avoids false positives like `chris` matching `christopher`)
- API Gateway was caching `/list` for 60 seconds, serving stale results after admin-side address assignment changes — disabled the Gateway cache on `/list`
- Client-side `ADDRESS_LIST` localStorage cache not invalidated by admin address-mutation endpoints — `assignAddress`, `unassignAddress`, and `newAddressAdmin` now bust it

## [0.4.1] - 2026-04-13

### Added

- Terraform module `terraform/infra/modules/certbot_renewal/` — container-image Lambda on EventBridge schedule (every 60 days) that runs certbot with `certbot-dns-route53`, writes certs to SSM, and forces ECS redeployments, replacing the ACME Terraform provider
- `lambda/certbot-renewal/` — Dockerfile and Python handler for the certbot renewal Lambda (arm64)
- React contexts: `AuthContext` and `AppMessageContext` to replace prop drilling for auth state and toast notifications
- React hook: `useApi` — centralizes `ApiClient` instantiation using auth context
- `ErrorBoundary` component wrapping Email, Addresses, and Folders views with fallback UI
- Code splitting with `React.lazy` + `Suspense` for Email, Folders, and Addresses views
- Dual Rich Text / Markdown editing modes in the compose editor
- Unit tests for React components (`AppMessage`, `Nav`, `Login`, `SignUp`, `ComposeOverlay`, `MessageOverlay`, `Envelopes`, `Messages`, `ErrorBoundary`)
- Vitest + jsdom test runner for React app
- ENI trunking for ECS (`awsvpcTrunking` account setting, `ECS_ENABLE_TASK_ENI` agent config, managed policy attachment) to support `awsvpc` tasks on Graviton instances
- IMDSv2 hop limit increased to 2 on ECS launch template for container metadata access
- Documentation: `docs/0.4.1/react-modernization-plan.md`, `docs/unreleased/sendmail-replacement.md`

### Fixed

- NAT instance iptables rules lost on reboot — replaced nested heredoc (which created an empty systemd unit file) with `printf`-based generation
- Sendmail crash loop on `smtp-out` caused by orphan daemon holding port 25 — added `sendmail-wrapper.sh` with PID file cleanup and supervisord retry configuration
- `this.stage` typo in `MessageOverlay/index.js`
- Nav layout: scoped absolute positioning to logout button only
- Race condition in `Envelopes` where multiple async `getEnvelopes` calls could overwrite pagination state
- Sequential `setState` calls in `MessageOverlay` that could overwrite each other
- Memory leak risk from timers in `Messages` — consolidated 5 timer IDs into properly cleaned-up effects
- JWT token security: moved from `localStorage` to module-level memory variable (no longer persisted to disk)
- `App.jsx` `setState` override no longer serializes password to `localStorage`
- `App.jsx` message toast timer leak — stale `setTimeout` could fire after unmount; now tracked in a ref and cleared properly
- Compose toolbar button alignment and formatting issues

### Changed

- **ECS architecture migrated from x86_64 to ARM64 (Graviton)** — AMI filter changed from `amzn2-ami-ecs-hvm` (x86_64) to `al2023-ami-ecs-hvm` (arm64); instance type changed from T3/T4g to M6g
- **React upgraded from 17 to 18** — `ReactDOM.render` replaced with `createRoot`, Strict Mode enabled
- **React build tooling migrated from Create React App to Vite** — new `vite.config.js`, `index.html` moved to root, scripts updated to `vite`/`vitest`, output directory changed from `build/` to `dist/`
- **All React components converted from class-based to functional** with hooks (`useState`, `useEffect`, `useRef`, `useContext`, `useCallback`)
- **Compose editor replaced**: draft-js (abandoned) replaced with TipTap — native HTML support, toolbar with formatting/lists/alignment/color/links, heading levels 1-4, rich text paste preservation
- CSS Modules migration — `AppMessage.css`, `Login.css`, `SignUp.css`, `Folders.css` renamed to `.module.css` with scoped `styles.className` imports
- React CI workflow (`.github/workflows/react.yml`) — switched from `yarn` to `npm`, updated build commands and artifact paths for Vite
- Docker CI workflow (`.github/workflows/docker.yml`) — added `certbot-renewal` to build matrix, uses native arm64 runner, pushes `:latest` tag for certbot image
- `App.jsx` converted from class to functional component — uses hooks, functional state updates, separated transient UI state (message/error/hideMessage) from persisted app state
- All React `.js` component files renamed to `.jsx`
- Cloud Map namespace renamed from `cabal.local` to `cabal.internal`
- `docs/0.4.1/user-management-plan.md` moved to `docs/0.5.0/` (deferred to next release)

### Removed

- **Chef/EC2 infrastructure decommissioned (Phase 7 cutover complete):**
  - `chef/` directory — entire Chef cookbook (recipes, templates, libraries, resources)
  - `.github/workflows/cookbook.yml` — cookbook build and S3 upload workflow
  - `terraform/infra/modules/asg/` — Auto Scaling Group module (launch templates, IAM instance profiles, security groups, userdata)
  - `cabal_chef_document` SSM document and its output/variable plumbing (`modules/app/ssm.tf`, `modules/user_pool/variables.tf`)
  - `lambda/counter/node/` — legacy Node.js counter Lambda that invoked Chef via SSM (replaced by Python version in 0.4.0)
  - Instance-type NLB target groups and conditional listener routing in `modules/elb/` — listeners now forward directly to ECS target groups
  - `chef_license`, `imap_scale`, `smtpin_scale`, `smtpout_scale` variables and their CI/CD tfvars wiring
- `terraform/infra/modules/cert/acme.tf` — ACME/Let's Encrypt Terraform provider approach (replaced by certbot Lambda)
- `acme` and `tls` provider requirements from `terraform/infra/modules/cert/versions.tf`
- `prod` and `email` variables from cert module (only used by ACME)
- `draft-js`, `react-draft-wysiwyg`, `draftjs-to-html`, `html-to-draftjs`, `markdown-draft-js` — 5 packages replaced by TipTap
- `yarn.lock` (switched to npm/`package-lock.json`)
- `.github/scripts/react-documentation.sh` and `react-docgen`-generated docs (`react/admin/docs/`)
- Unused React dependencies: `react-lazyload`, `react-docgen`
- `greet_pause` from `smtp-out` sendmail template

## [0.4.0] - 2026-03-15

### Added

- Documentation `docs/0.4.0/containerization-plan.md` — detailed migration plan documenting the containerization strategy
- Terraform module `terraform/infra/modules/ecs/` — ECS cluster with three services (IMAP, SMTP-IN, SMTP-OUT), task definitions, auto-scaling, capacity provider, Cloud Map service discovery, and all associated IAM roles
- Terraform module `terraform/infra/modules/ecr/` — container image repositories for the three mail services
- Docker images and scripts — three Dockerfiles (`imap`, `smtp-in`, `smtp-out`), shared entrypoint/reconfiguration/user-sync scripts, supervisord configs, Dovecot/sendmail/OpenDKIM configs, PAM auth integration, and sendmail `.mc` templates
- SNS/SQS fan-out for notifying containers of address changes (replacing SSM `SendCommand`)
- `address_changed_topic_arn` to all API Lambda functions
- `sns:Publish` IAM permissions to Lambda execution roles
- `nlb_arn` output
- `terraform/infra/modules/vpc/ROLLBACK.md`** — NAT instance migration rollback instructions
- DNS module — `locals.tf` with CI/CD build workflow metadata
- Workflow: `docker_build_push.yml` for building and pushing Docker images
- Terraform workflow: `image_tag` input and SSM update step for Docker image deployments
- Counter workflow: pylint step for Python linting

### Fixed

- `assign_osid` Lambda: removed SSM permissions, added `ecs:UpdateService` permission to trigger redeployments
- Minor whitespace formatting change in `dovecot-15-mailboxes.conf` (no behavioral impact)

### Changed

- Three API functions and the Cognito post-confirmation trigger were rewritten from Node.js to Python:
    - **`list`** — rewritten from `lambda/api/node/list/index.js` to Python
    - **`new`** — rewritten from `lambda/api/node/new/index.js` to Python
    - **`revoke`** — rewritten from `lambda/api/node/revoke/index.js` to Python, now includes proper authorization checks (`user_authorized_for_sender`) and shared-subdomain safety checks
    - **`assign_osid`** (counter) — rewritten from Node.js to Python, now triggers ECS redeployments instead of Chef via SSM
    - **Added `lambda/api/new_address/function.py`** — new function with DKIM key generation
- Directory restructuring: Python Lambda functions moved from `lambda/api/python/` to `lambda/api/` (cleaner layout now that Node.js versions are removed).
- Python Lambda layer runtime upgraded from `python3.9` to `python3.13`
- Removed Node.js Lambda layer (no longer needed)
- Lambda functions no longer carry a `type` field — all are Python with a unified layer and handler
- Added S3 pre-flight checks that gate layer/function creation on zip existence
- SSM Parameter Store replaced with remote state — the `infra` stack now reads zone data via `terraform_remote_state` from the `dns` stack instead of SSM parameters (`/cabal/control_domain_zone_id`, `/cabal/control_domain_zone_name`)
- All four NLB listeners (IMAP/143, relay/25, submission/465, STARTTLS/587) now include ECS cutover conditionals, allowing gradual traffic migration from ASG to ECS target groups
- Added private DNS records for Cloud Map service discovery
- S3 bucket hardening — explicit `acl = "private"` on cache and React app buckets
- Backup vault — `prevent_destroy` changed from `true` to `false` (flexibility during active development)
- Counter build script: converted from Node.js npm to Python pip packaging
- React workflow: upgraded `actions/upload-artifact` and `actions/download-artifact` from v3 to v4

### Removed

- `ssm:SendCommand` and `ssm:StartSession` permissions (no longer targeting EC2 directly)
- `lambda_api_node.yml` and `build-api-node.sh` (Node.js Lambda no longer needed)
- `build-api-python.sh` → `build-api.sh` (Python is now the sole Lambda runtime)

### Deprecated

- Chef will be removed in 0.4.1
- ACME/Let's Encrypt certificate will be removed in 0.4.1

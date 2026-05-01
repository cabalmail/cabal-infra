# Build and Deploy Simplification Plan

## Context

The build/deploy pipeline grew organically as new artifact types were added: first Terraform, then Lambda zips, then a React bundle, then container images, then a monitoring stack. Each addition was bolted on as a sibling workflow that ultimately re-entered `terraform.yml` to do the actual deployment. The result has three concrete pain points the operator runs into routinely:

1. **ECR chicken-and-egg on first run.** [`docker.yml`](../../.github/workflows/docker.yml) pushes images to ECR repositories that [`terraform/infra/modules/ecr/main.tf`](../../terraform/infra/modules/ecr/main.tf) creates. On a fresh deployment, neither side can proceed without the other. The recovery is "let Terraform fail, build the image, run Terraform again." It works; it is ugly; it cannot be automated as written.

2. **Multi-trigger Terraform storms.** [`terraform.yml`](../../.github/workflows/terraform.yml) is reachable five different ways: its own `push` path filter, `workflow_dispatch`, `repository_dispatch`, and `workflow_call` from each of [`docker.yml:129`](../../.github/workflows/docker.yml:129), [`lambda_api_python.yml:36`](../../.github/workflows/lambda_api_python.yml:36), and [`lambda_counter.yml:36`](../../.github/workflows/lambda_counter.yml:36). A coordinated changeset that touches `terraform/infra/`, `lambda/api/`, `lambda/counter/`, and `docker/` triggers Terraform four times serially - none of which are cancelled or coalesced. There is no `concurrency:` block on any workflow.

3. **Unconditional monitoring image builds.** [`docker.yml:31-46`](../../.github/workflows/docker.yml:31-46) builds 12 tiers in matrix on every push to `docker/**`. Nine of those (`uptime-kuma`, `ntfy`, `healthchecks`, `prometheus`, `alertmanager`, `grafana`, `cloudwatch-exporter`, `blackbox-exporter`, `node-exporter`) are gated downstream by `var.monitoring` ([`terraform/infra/main.tf:217-219`](../../terraform/infra/main.tf:217-219)). When `TF_VAR_MONITORING=false` they are still built, pushed to ECR, and pay arm64 build minutes for nothing.

This plan replaces the workflow graph with a two-workflow model that builds in parallel, deploys without re-entering Terraform, and exits the chicken-and-egg cleanly. It is targeted at the `0.9.0` milestone. Each phase is reversible; the cutover happens in phase 6.

## Goals

- A single push to any combination of `docker/**`, `lambda/**`, `react/**`, and `terraform/infra/**` results in **at most one** Terraform run and **one** parallel application build.
- Application code (container images, Lambda zips, React bundle) is deployable to running infrastructure **without** running Terraform.
- Container images are built only for tiers actually deployed by the current `TF_VAR_MONITORING` value.
- A first-time deploy succeeds end-to-end without operator intervention between steps.
- Workflow count drops from nine to five (`infra.yml`, `app.yml`, `apple.yml`, `destroy_terraform.yml`, `dependabot.yml`).
- The cutover is reversible at every phase; any phase can be abandoned and the pipeline still works.

## Non-goals

- Replacing GitHub Actions, Terraform Cloud token usage, or the S3 backend.
- Changing the artifact storage layout (ECR repo names, S3 keys, SSM parameter paths). Storage stays identical so older Terraform state and tooling keep working.
- Changing how `config.js` or other runtime configuration is delivered to the React app.
- Folding `apple.yml` into `app.yml`. The Apple build is a separate concern with separate runners (macOS) and gates nothing on the AWS side.
- Per-PR ephemeral environments. Out of scope; the current dev/stage/prod model stands.
- Replacing the per-workflow IAM secret model with OIDC (`aws-actions/configure-aws-credentials`). Worth doing later but orthogonal to this refactor.
- Image content scanning (Trivy on container images). Tracked separately under [`iac-quality-gates-plan.md`](iac-quality-gates-plan.md).

## Current state (audit)

### Workflow inventory

| Workflow | Push trigger paths | `workflow_call` from | Outputs |
|---|---|---|---|
| `terraform.yml` | `terraform/infra/**`, helper scripts | `docker.yml`, `lambda_api_python.yml`, `lambda_counter.yml` | SSM `/cabal/deployed_image_tag`, applied state |
| `docker.yml` | `docker/**`, `lambda/certbot-renewal/**` | none | ECR images (12 tiers + certbot-renewal), then calls `terraform.yml` |
| `lambda_api_python.yml` | `lambda/api/**`, helper scripts | none | S3 zips at `s3://admin.${CONTROL_DOMAIN}/lambda/`, then calls `terraform.yml` |
| `lambda_counter.yml` | `lambda/counter/**` | none | S3 zip + `.base64sha256` sidecar, then calls `terraform.yml` |
| `react.yml` | `react/admin/**` | none | `s3 sync` to admin bucket; CloudFront invalidation; **does not** call `terraform.yml` |
| `bootstrap.yml` | none (manual only) | none | terraform/dns state |
| `apple.yml` | `apple/**` | none | xcodebuild test results |
| `destroy_terraform.yml` | none (manual only) | none | destroyed state |
| `dependabot.yml` | schedule (daily) | none | PRs |

### Cross-workflow trigger graph (today)

```
push docker/**         -->  docker.yml         --workflow_call-->  terraform.yml
push lambda/api/**     -->  lambda_api*.yml    --workflow_call-->  terraform.yml
push lambda/counter/** -->  lambda_counter.yml --workflow_call-->  terraform.yml
push react/admin/**    -->  react.yml          (direct S3, no terraform)
push terraform/infra/**-->  terraform.yml      (own push trigger)
```

A push touching `docker/`, `lambda/api/`, `lambda/counter/`, **and** `terraform/infra/` produces four independent runs of `terraform.yml`, each doing a full plan, three scanners, and an apply if there is a diff. None are coalesced.

### Image-tag handoff

Container images use a single uniform tag `sha-${GITHUB_SHA::8}` ([`docker.yml:25`](../../.github/workflows/docker.yml:25)) for **all** tiers. The tag is written to SSM `/cabal/deployed_image_tag` by [`terraform.yml:157-164`](../../.github/workflows/terraform.yml:157-164), read by [`terraform/infra/main.tf:14-16`](../../terraform/infra/main.tf:14-16), and threaded into ECS task definitions through `module.ecs`. Because every tier carries the same tag, a single SSM update covers the whole fleet.

Lambda zips use a different mechanism: the workflow uploads `${func}.zip` and `${func}.zip.base64sha256` to S3, and Terraform reads the sidecar checksum at plan time ([`terraform/infra/modules/app/modules/call/lambda.tf:147-153`](../../terraform/infra/modules/app/modules/call/lambda.tf:147-153)). Any code change shows as a Terraform diff and requires a `terraform apply` to take effect.

The React app uses a third pattern: direct `aws s3 sync` from the workflow with no Terraform involvement. This is the shape we want for everything.

### Monitoring conditional gating

- Build: **none.** All 12 tiers are in the matrix unconditionally.
- ECR repo creation: **none.** All 12 + certbot-renewal are created unconditionally via [`terraform/infra/main.tf:137-156`](../../terraform/infra/main.tf:137-156).
- ECS task/service deployment: **gated** by `var.monitoring` at [`terraform/infra/main.tf:217-219`](../../terraform/infra/main.tf:217-219).

So monitoring images cost CI minutes on every push and ECR storage forever, even when nothing is consuming them.

## Target state

### Two-workflow model

```
push docker/** | lambda/** | react/**  -->  app.yml      (parallel build + deploy)
push terraform/infra/** | terraform/dns/**  -->  infra.yml  (bootstrap stage + main stage)
```

- `app.yml` builds artifacts in parallel and deploys directly to running infrastructure via AWS CLI calls. It does **not** call Terraform.
- `infra.yml` owns the topology and only runs when Terraform code changes (or on schedule for drift detection). It does **not** know about specific image tags or zip contents at apply time; those are out-of-band.
- Other workflows (`apple.yml`, `destroy_terraform.yml`, `dependabot.yml`) are unchanged.

### Trigger graph (target)

```
push docker/<tier>/**       \
push lambda/api/<func>/**    \    path-filter
push lambda/counter/**        ->  app.yml  ->  per-job parallel build  ->  per-job parallel deploy
push lambda/certbot-renewal   /                                              (ECS update-service,
push react/admin/**          /                                                Lambda update-function-code,
                                                                              S3 sync + CF invalidate)

push terraform/dns/**        \
push terraform/infra/**       ->  infra.yml  ->  bootstrap (if dns/ changed)  ->  scan + plan + apply
push .github/scripts/...     /                                  ^
                                                                |
schedule (weekly Wednesday) -+
workflow_dispatch ----------+
```

### Decoupling Terraform from artifact churn

For Terraform to stop re-running on artifact changes, the task definitions and Lambda functions need to be authored such that the artifact reference can be mutated out-of-band without Terraform reverting it on the next plan.

**ECS approach.** The task definition will continue to read `/cabal/deployed_image_tag` from SSM at plan time, but the `aws_ecs_task_definition` resource gets:

```hcl
lifecycle {
  ignore_changes = [container_definitions]
}
```

The first `terraform apply` writes a task def using the SSM value as the initial image tag. Subsequent app deploys update the task def out-of-band by registering a new revision via `aws ecs register-task-definition` (Terraform retains the rendered JSON in state but does not assert on it). `aws ecs update-service` rolls the service to the new revision. On a future Terraform run that legitimately changes task topology (cpu, memory, env, secrets, network, IAM), the next-plan output regenerates the full container_definitions; we accept this as the controlled re-pin point. A pre-apply step in `infra.yml` reads the currently-running task def for each service and refreshes SSM so that the regenerated container_definitions match what is already deployed - i.e., the apply does not silently roll back the most recent image deploy.

**Lambda approach.** Lambda functions get an analogous lifecycle clause:

```hcl
lifecycle {
  ignore_changes = [s3_key, s3_object_version, source_code_hash]
}
```

App deploys call `aws lambda update-function-code --s3-bucket ... --s3-key ...` directly. The pre-apply hook in `infra.yml` records the currently-deployed `CodeSha256` per function and writes it into the tfvars file so that a topology-only Terraform apply does not roll back code that has been independently deployed.

Both clauses are introduced in phase 1 and phase 2 below; the lifecycle change is a no-op until phase 3 starts using out-of-band deployments.

### Bootstrap absorption

`bootstrap.yml` becomes a `bootstrap` job inside `infra.yml`, gated on whether `terraform/dns/**` changed (or on `workflow_dispatch` with a `bootstrap: true` input). `infra.yml` runs `bootstrap` first, then the main `infra` job. On a steady-state push that touches only `terraform/infra/**`, the bootstrap job is skipped via `if:` and adds no time. The standalone `bootstrap.yml` is deleted.

### First-run / chicken-and-egg

The new `infra.yml` plants **placeholder image tags** in SSM and a **placeholder Lambda zip** in S3 before its first apply, removing the dependency on `app.yml` having ever run:

1. `infra.yml` first-run logic checks if `/cabal/deployed_image_tag` exists. If not, it writes a sentinel value `bootstrap-placeholder`. Task definitions are authored to accept this sentinel: the ECR module also publishes a public `nginx:alpine` mirror (or, simpler, the task def references `public.ecr.aws/nginx/nginx:stable` directly when SSM is `bootstrap-placeholder`). A `locals` block does the substitution.
2. Similarly for Lambda: if `${func}.zip` is missing in S3, a stub zip ("placeholder Lambda - replace with real deploy") is uploaded by an `infra.yml` pre-apply step. Lambda functions are created with the stub.
3. Once `infra.yml` succeeds, ECR repositories exist. The operator (or CI on the next push) runs `app.yml`, which builds real images and zips and deploys them. No second Terraform run is required.

This trades a small amount of placeholder logic in Terraform for full automation of the first deploy.

### Monitoring matrix gating

`app.yml` reads `vars.TF_VAR_MONITORING` and computes the docker matrix dynamically:

```yaml
- id: matrix
  run: |
    CORE='["imap","smtp-in","smtp-out"]'
    MON='["uptime-kuma","ntfy","healthchecks","prometheus","alertmanager","grafana","cloudwatch-exporter","blackbox-exporter","node-exporter"]'
    if [ "${{ vars.TF_VAR_MONITORING }}" = "true" ]; then
      echo "tiers=$(jq -cn --argjson c "$CORE" --argjson m "$MON" '$c + $m')" >> "$GITHUB_OUTPUT"
    else
      echo "tiers=$CORE" >> "$GITHUB_OUTPUT"
    fi
```

The matrix `tier` axis becomes `${{ fromJson(needs.matrix.outputs.tiers) }}`. ECR repos for monitoring tiers stay created unconditionally with `lifecycle { prevent_destroy = true }` so toggling monitoring off does not destroy historical images, but no build minutes are spent.

### Path-filtered builds in `app.yml`

Today every push to `docker/**` rebuilds all 12 tiers. The target is per-tier filtering: a change to `docker/imap/Dockerfile` rebuilds only `imap`. We use `dorny/paths-filter@v3` (or equivalent) at the top of `app.yml` to compute which tiers, which Lambda functions, the React app, and the certbot Lambda actually changed, and skip the unchanged ones. The existing `shared/`, `templates/`, and `common/` directories remain rebuild-all triggers since every tier consumes them.

For Lambda: `lambda/api/**` is currently rebuilt as a single zip-set by [`build-api.sh`](../../.github/scripts/build-api.sh). The simplest path-filter rule is "any change in `lambda/api/` rebuilds all api functions" (preserving today's behavior). A per-function filter is a follow-on optimization.

### Environment gating (preserved)

Both new workflows continue to use the existing branch-to-environment mapping (`main`->prod, `stage`->stage, other->development) on every job that touches AWS, exactly as today's [`terraform.yml:31`](../../.github/workflows/terraform.yml:31) and [`docker.yml:30`](../../.github/workflows/docker.yml:30) do. The GitHub `environment: prod` required-reviewer gate that is already configured upstream of those jobs is inherited unchanged - this plan does not bypass, weaken, or relocate that approval flow. Phase 6's cutover specifically preserves the `environment:` block on the deploy and apply jobs of `app.yml` and `infra.yml`.

### Concurrency control

Both `infra.yml` and `app.yml` get:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false
```

`cancel-in-progress: false` keeps deploy-then-deploy ordered correctly (we never want a half-applied state from a cancelled apply). For `app.yml`, it queues subsequent app builds behind in-flight ones. For `infra.yml`, it serialises Terraform applies per branch.

## Migration phases

Each phase is independently mergeable and reversible. Phases 1-3 are pure Terraform/scripting changes that introduce no behavior change and can land progressively. The cutover is phase 6.

### Phase 0: Baseline measurement

- Record current per-push CI minutes for a representative changeset that exercises all four app workflows + Terraform. This is the baseline the simplification needs to beat.
- Document the current first-run procedure (the ugly chicken-and-egg recovery) in `docs/0.9.0/build-deploy-simplification-plan.md` so we have a "before" reference if rollback is ever needed.
- No code changes.

### Phase 1: ECS task-definition lifecycle

- Add `lifecycle { ignore_changes = [container_definitions] }` to every `aws_ecs_task_definition` in `terraform/infra/modules/ecs` and `terraform/infra/modules/monitoring`.
- Add a Terraform pre-plan helper script `.github/scripts/refresh-ssm-from-running.sh` that reads the running task def's image tag for each service and writes it back to `/cabal/deployed_image_tag` if it differs. Wire into `infra.yml` at the start of plan.
- No-op change in steady state. Phase regression test: push a Terraform-only change (e.g., a comment in a non-ECS module) and confirm no task def diffs surface.

### Phase 2: Lambda function lifecycle

- Add `lifecycle { ignore_changes = [s3_key, s3_object_version, source_code_hash] }` to `aws_lambda_function` resources in `terraform/infra/modules/app/modules/call/lambda.tf` and the certbot module.
- Extend the pre-plan helper to record `CodeSha256` for each function and write it to a `.terraform/lambda-pinned.tfvars` file consumed by the apply step (so a topology-only apply does not unpin code).
- Same regression test: a Terraform-only change should produce zero Lambda code diffs.

### Phase 3: New `app.yml` (running in parallel with old workflows)

- Author `.github/workflows/app.yml` with: per-changed-area path filter, parallel build matrix (docker tiers, lambda functions, react), parallel deploy jobs that call AWS CLI directly (`aws ecs register-task-definition` + `aws ecs update-service`, `aws lambda update-function-code`, `aws s3 sync` + CloudFront invalidation).
- `app.yml` runs on `workflow_dispatch` only at first. Operator triggers it manually to validate end-to-end behavior on the dev environment.
- The existing `docker.yml`, `lambda_api_python.yml`, `lambda_counter.yml`, `react.yml` keep running normally. Both pipelines coexist briefly.

### Phase 4: Placeholder bootstrap logic

- In `terraform/infra`, add the SSM-sentinel substitution and stub-zip materialisation logic described under [First-run](#first-run--chicken-and-egg).
- Validate by destroying the dev environment and reapplying from scratch with no prior images or zips. Expected: `infra.yml` succeeds end-to-end with placeholder workloads; subsequent `app.yml` deploys real artifacts; second `infra.yml` apply produces zero diffs.

### Phase 5: New `infra.yml` (replacing `terraform.yml` + `bootstrap.yml`)

Shipped in 0.9.4.

- Author `.github/workflows/infra.yml` with `bootstrap` and `apply` jobs. Bootstrap is gated on path filter for `terraform/dns/**` or explicit `workflow_dispatch` input.
- Add the concurrency block.
- Add a `post_apply` job that runs `.github/scripts/post-apply-update-services.sh` to roll every ECS service to its task-def family head, closing the gap left by the phase 1 `ignore_changes = [task_definition]` clause for topology-only Terraform changes.
- Initially deployed alongside `terraform.yml` (renamed to `terraform-legacy.yml` and stripped of its `push` trigger, kept as a manual escape hatch for one release cycle in case rollback is needed).

**Deviation from the original plan as written.** The original phase 5 said "stripped of all push and workflow_call triggers." `workflow_call` was *not* stripped from `terraform-legacy.yml` because `docker.yml` / `lambda_api_python.yml` / `lambda_counter.yml` still reference it via `uses:`; their `uses:` was redirected from `terraform.yml` to `terraform-legacy.yml`. Stripping `workflow_call` would have surfaced as workflow validation errors in those callers until phase 6 deletes them. The trade-off: during the dual-pipeline window, a push to `docker/**` / `lambda/**` still chains into a Terraform apply via the legacy file, so phase 5 does *not* yet achieve the "at-most-one Terraform run per push" goal - that goal is only reached in phase 6 once the callers are gone.

### Phase 6: Cutover

- Add `app.yml` push triggers for `docker/**`, `lambda/**`, `react/admin/**`.
- Delete `docker.yml`, `lambda_api_python.yml`, `lambda_counter.yml`, `react.yml`, `bootstrap.yml`. The `workflow_call` chain into `terraform-legacy.yml` goes away with these files - there are no longer any callers, so step "Remove `workflow_call` blocks from the legacy app workflows" from the original plan is satisfied automatically.
- Delete `terraform-legacy.yml`. Phase 5 deferred this for "one release cycle" as a rollback escape hatch; the 0.9.4 CHANGELOG `Deprecated` section announced removal in the next release, so phase 6 is the next release. Removing `terraform-legacy.yml` simultaneously removes its `workflow_call` interface, so phase 7's "Delete unused fields in `terraform.yml` `workflow_call` interface" is also moot.
- Remove the `repository_dispatch` listener that lived on `terraform.yml` (now `terraform-legacy.yml`) when that file is deleted. Originally listed under phase 7 but folded forward since deleting the file is the same action.
- Land monitoring matrix filter and `prevent_destroy` on monitoring ECR repos.
- Update [`CLAUDE.md`](../../CLAUDE.md) workflow table.

### Phase 7: Cleanup

- Audit and remove any cron triggers on legacy workflows.
- Update `docs/operations/` runbooks that reference deleted workflows.

(Two items from the original phase 7 - removing `repository_dispatch` listeners and deleting unused `workflow_call` interface fields - were folded into phase 6 because deleting `terraform-legacy.yml` outright accomplishes both.)

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `ignore_changes` causes Terraform and AWS to silently disagree on task def contents over time | Medium | Medium | Pre-plan helper actively reconciles SSM with running state; quarterly audit script compares Terraform-rendered task def to running revision and reports drift |
| Out-of-band ECS deploy fails partway (image pushed but task def not updated) | Low | High | `app.yml` deploy step is idempotent and re-runnable; ECS deployment circuit breaker auto-rolls-back on health-check failure; include Slack/email alert hook on failure |
| Lambda update-function-code race with concurrent Terraform apply | Low | Medium | Concurrency group on `app.yml` and `infra.yml` is *separate*, so they can run concurrently; mitigate by adding a cross-workflow advisory lock via a shared SSM parameter (`/cabal/deploy-lock`) checked at apply start |
| First-run placeholder image fails to start on private ECS subnet (no public registry egress) | Medium | High | Confirm dev VPC has NAT egress before phase 4; if no egress, use an Amazon-public ECR mirror as the placeholder source; verified during phase 4 destroy/recreate test |
| Monitoring matrix gating accidentally drops a tier that the running cluster still references | Low | High | `prevent_destroy` on ECR; ECS module also gated by `var.monitoring`, so service is gone before its image build is gone |
| Path-filter false negatives skip a needed rebuild | Medium | Medium | First two weeks after cutover, also include `workflow_dispatch` runs that force-rebuild-all and compare digests; alert on any mismatch |
| Operator confusion during the dual-pipeline window (phases 3-5) | High | Low | README / CLAUDE.md prominently document which pipeline is canonical at each phase; send a Slack note at the start of each phase |

## Alternatives considered

- **Keep terraform-as-deployer; add concurrency control only.** Cheapest fix - one `concurrency:` block on `terraform.yml` would coalesce the storms in pain point 2. Rejected as the primary plan because it does not address pain points 1 (chicken-and-egg) or 3 (unnecessary builds), and leaves Terraform on the critical path of every code deploy. Worth doing **as an immediate stopgap** before phase 1 ships - a one-line PR that sets `concurrency: { group: terraform-${{ github.ref }}, cancel-in-progress: false }` on `terraform.yml` is reversible and buys time.

- **Move to AWS CodePipeline / CodeBuild.** Rejected. Adds a second build platform with its own auth, observability, and IaC surface; the GitHub Actions setup is already adequate once simplified.

- **Use `:latest` tags and rely on `ECS_IMAGE_PULL_BEHAVIOR=always`.** Rejected. Loses immutable tag traceability; complicates rollback (the previous `:latest` is gone); incompatible with the existing SSM-based audit trail.

- **Per-PR ephemeral environments via Terraform workspaces.** Out of scope for 0.9.0. Could become a future option once `infra.yml` is decoupled from the deploy critical path.

- **Single mono-workflow.** A single `cabalmail.yml` that routes via path filters to all build paths. Rejected because it conflates `infra` (slow, scanner-heavy, sensitive) with `app` (fast, frequent, lower-risk gates). The two-workflow split keeps the gates appropriate to the change type.

## Cutover and rollback

The cutover happens in phase 6. Rollback at any earlier phase is a `git revert` of the offending PR; phases 1-5 do not break the existing pipeline.

Phase 6 rollback: re-enable `terraform-legacy.yml` `push` and `workflow_call` triggers, remove the new `app.yml` push triggers, restore the deleted workflows from git history. The lifecycle clauses from phases 1-2 remain (they are no-ops in the legacy flow). Estimated rollback time: 15 minutes.

## Open questions

- **Schedule for the weekly Terraform run.** [`terraform.yml`](../../.github/workflows/terraform.yml) currently runs weekly (per [`CLAUDE.md`](../../CLAUDE.md) - though the actual `schedule:` block is not in the workflow file as audited). Confirm whether weekly drift detection is wanted on `infra.yml` and at what time; the schedule is unchanged in this plan but should be re-validated.
- **Concurrency mode for prod.** `cancel-in-progress: false` is conservative. For dev, `cancel-in-progress: true` on `app.yml` would let rapid-fire pushes skip intermediate builds. Decide per-environment.
- **Per-Lambda-function path filtering.** Phase 3 keeps "any `lambda/api/**` change rebuilds all" for simplicity. A per-function filter would be a small follow-on - decide whether to bundle into phase 6 or defer.
- **Should `apple.yml` move under `app.yml` someday?** No technical blocker, but the runner type (macOS) and the "deploy" semantics (no AWS-side action) are different enough that keeping it separate is probably right indefinitely.

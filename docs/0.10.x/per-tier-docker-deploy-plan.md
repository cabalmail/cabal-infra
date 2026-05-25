# Per-Tier Docker Build and Deploy Plan

## Context

The application-deploy pipeline already path-filters at the *area* level (docker vs lambda_api vs react vs front_door vs ...) via [`dorny/paths-filter`](../../.github/workflows/app.yml) - a change under `lambda/api/**` does not run the docker job, and vice versa. Inside the docker area, however, the granularity stops: any change under `docker/**` triggers the `docker` job, and that job's matrix fans out to *every* tier in scope ([`app.yml:190-198`](../../.github/workflows/app.yml)). Each matrix cell unconditionally builds, pushes a fresh `sha-XXXXXXXX` image, registers a new ECS task-definition revision, and calls `aws ecs update-service`.

The cost shows up two ways:

1. **CI minutes.** A change to `docker/imap/configs/dovecot/10-mail.conf` rebuilds smtp-in, smtp-out, and (when monitoring is on) nine monitoring containers. With the monitoring matrix enabled the wasted arm64 build minutes are 4-12x what the change actually needs.
2. **Service rolls on tiers that didn't change.** Every matrix cell ends with an ECS `update-service`, which registers a new task-def revision and starts a rolling deploy. For smtp-in / smtp-out / monitoring tiers this is brief and harmless; for IMAP it triggers the 2-4 minute client-facing gap documented in [`imap-deploy-downtime-plan.md`](./imap-deploy-downtime-plan.md). A change that has nothing to do with IMAP should not cause an IMAP outage. Today it does.

The Dockerfile inputs make per-tier filtering tractable. The three core tiers ([`docker/imap/Dockerfile`](../../docker/imap/Dockerfile), [`docker/smtp-in/Dockerfile`](../../docker/smtp-in/Dockerfile), [`docker/smtp-out/Dockerfile`](../../docker/smtp-out/Dockerfile)) share `docker/shared/` and consume one of three sendmail templates from `docker/templates/`. Monitoring tiers and the sinkhole tier sit in their own subdirectories and consume neither `docker/shared/` nor `docker/templates/` - they are independent.

The one real design decision is the image-tag model. Today every tier shares one `sha-${SHA::8}` tag, and Terraform reads it from SSM (`/cabal/deployed_image_tag`) at plan time. If unchanged tiers stay on previous tags while siblings advance, the SSM model has to become per-tier, or we have to retag the unchanged image as the new global SHA in ECR. This plan picks per-tier SSM because it more honestly reflects what is already true at the ECS task-def level (each task-def has always carried its own image reference; the unified tag was a build-time convenience).

## Goals

- A push that touches only `docker/imap/**` builds and rolls only IMAP. The smtp-in, smtp-out, and monitoring services stay on their existing task-def revisions and existing image tags. No `update-service` call against them. No NLB target reshuffle. No IMAP gap on unrelated changes.
- A push to `docker/shared/**` correctly rebuilds and rolls all three core tiers (they all consume the shared scripts). Monitoring tiers stay untouched.
- A push to `docker/templates/imap-sendmail.mc` rebuilds only IMAP. `in-sendmail.mc` rebuilds only smtp-in. `out-sendmail.mc` rebuilds only smtp-out.
- `workflow_dispatch` keeps an escape hatch for "rebuild and roll everything" - covers first-time deploys, base-image refreshes, and operator-initiated catchups.
- The per-tier matrix continues to honour `vars.TF_VAR_MONITORING` and `vars.TF_VAR_SINKHOLE` gates as today; per-tier filtering composes with those, not replaces them.
- ECR retention (10 most recent tagged images per repo, [`terraform/infra/modules/ecr/main.tf:117-150`](../../terraform/infra/modules/ecr/main.tf)) keeps slow-moving tiers' images alive. Per-tier filtering improves this picture: fewer wasted pushes against repos whose contents did not change.
- The Terraform plan-time read of the deployed image tag continues to work after a topology-only apply: each tier's regenerated task-def pins to the correct tag for that tier, not to whichever tier was deployed most recently.

## Non-goals

- Base-image rolling. AL2023 CVE-driven rebuilds need a "scheduled rebuild of everything" mechanism (probably a weekly cron `workflow_dispatch areas=docker,full=true`). Out of scope for this plan; tracked separately.
- Content-addressed image tags (e.g. `sha256-<digest-of-tier-inputs>`). The SHA-based tag is fine; changing the tag scheme would force a wider migration of refresh-ssm logic and Terraform's plan-time read.
- Per-file caching inside `docker buildx`. Layer caching already works; the win here is skipping the deploy step on unchanged tiers, not making the build step faster on changed ones.
- Per-tier filtering for Lambda functions. The `lambda-api` job already does parallel deploy across functions via `xargs -P` ([`app.yml:358-386`](../../.github/workflows/app.yml)); the `pylint` step that runs across all of them is cheap. Not worth changing.
- Splitting the docker matrix across multiple jobs. The matrix shape is correct; only the *contents* of the matrix change with this plan.
- Removing the global SSM `/cabal/deployed_image_tag` parameter. It is still useful as a bootstrap sentinel ([`terraform/infra/modules/ecs/locals.tf:24-45`](../../terraform/infra/modules/ecs/locals.tf)). It can remain as the default fallback even after per-tier keys land.

## Current state (audit)

### Per-tier Dockerfile inputs

```
docker/imap/Dockerfile
  COPY imap/configs/dovecot/*           # tier-specific
  COPY imap/configs/pam/dovecot         # tier-specific
  COPY imap/configs/procmailrc          # tier-specific
  COPY imap/supervisord.conf            # tier-specific
  COPY shared/aliases.static            # shared
  COPY shared/entrypoint.sh             # shared
  COPY shared/generate-config.sh        # shared
  COPY shared/sync-users.sh             # shared
  COPY shared/reconfigure.sh            # shared
  COPY shared/sendmail-wrapper.sh       # shared
  COPY shared/rsyslog-mail.conf         # shared
  COPY templates/imap-sendmail.mc       # template (IMAP only)

docker/smtp-in/Dockerfile
  COPY smtp-in/supervisord.conf         # tier-specific
  COPY shared/entrypoint.sh             # shared
  COPY shared/generate-config.sh        # shared
  COPY shared/sync-users.sh             # shared
  COPY shared/reconfigure.sh            # shared
  COPY shared/sendmail-wrapper.sh       # shared
  COPY shared/hosts-pin.sh              # shared
  COPY shared/rsyslog-mail.conf         # shared
  COPY templates/in-sendmail.mc         # template (smtp-in only)

docker/smtp-out/Dockerfile
  COPY smtp-out/configs/dovecot/*       # tier-specific
  COPY smtp-out/configs/pam/dovecot     # tier-specific
  COPY smtp-out/configs/opendkim.conf   # tier-specific
  COPY smtp-out/configs/out-access      # tier-specific
  COPY smtp-out/supervisord.conf        # tier-specific
  COPY shared/entrypoint.sh             # shared
  COPY shared/generate-config.sh        # shared
  COPY shared/sync-users.sh             # shared
  COPY shared/reconfigure.sh            # shared
  COPY shared/sendmail-wrapper.sh       # shared
  COPY shared/rsyslog-mail.conf         # shared
  COPY templates/out-sendmail.mc        # template (smtp-out only)

docker/sinkhole/Dockerfile               # independent
docker/uptime-kuma/Dockerfile            # independent
docker/ntfy/Dockerfile                   # independent
docker/healthchecks/Dockerfile           # independent
docker/prometheus/Dockerfile             # independent
docker/alertmanager/Dockerfile           # independent
docker/grafana/Dockerfile                # independent
docker/cloudwatch-exporter/Dockerfile    # independent
docker/blackbox-exporter/Dockerfile      # independent
docker/node-exporter/Dockerfile          # independent
```

`grep -l "COPY shared\\|COPY templates" docker/*/Dockerfile` confirms only the three core tiers cross-import shared scripts. Monitoring tiers and the sinkhole tier are self-contained per-Dockerfile.

### Today's path filter

[`.github/workflows/app.yml:122-147`](../../.github/workflows/app.yml):

```yaml
filters: |
  docker:
    - 'docker/**'
    - '.github/scripts/deploy-ecs-service.sh'
```

One filter, all-or-nothing for the entire docker matrix.

### Today's tag and SSM model

- Build tag computed once in setup ([`app.yml:80-82`](../../.github/workflows/app.yml)): `image_tag=sha-${GITHUB_SHA::8}`.
- Every docker matrix cell pushes that same tag.
- [`deploy-ecs-service.sh`](../../.github/scripts/deploy-ecs-service.sh) rewrites the image reference inside the cloned task-def to the new tag and registers a revision; the script does not touch SSM.
- [`refresh-ssm-from-running.sh`](../../.github/scripts/refresh-ssm-from-running.sh) (run at the start of `infra.yml`'s Terraform plan job) reads the running tag from the **canonical** service `cabal-imap` and writes it to `/cabal/deployed_image_tag`. The script is hard-coded to inspect the IMAP service:
  ```bash
  CLUSTER="${CLUSTER:-cabal-mail}"
  CANONICAL_SERVICE="${CANONICAL_SERVICE:-cabal-imap}"
  CANONICAL_CONTAINER="${CANONICAL_CONTAINER:-imap}"
  SSM_PARAM="${SSM_PARAM:-/cabal/deployed_image_tag}"
  ```
- Terraform's [`local.tier_image`](../../terraform/infra/modules/ecs/locals.tf) maps every tier to `${ecr_repo}:${image_tag}` where `image_tag` is the one SSM value. On a topology-only apply that regenerates a task-def, all tiers get the same tag.

If we let tiers diverge in tag while siblings advance, the canonical-service read in `refresh-ssm-from-running.sh` becomes wrong for the non-IMAP tiers, and Terraform-driven task-def regenerations would re-pin those tiers to whatever tag IMAP happens to be on.

### ECR retention

[`terraform/infra/modules/ecr/main.tf:117-150`](../../terraform/infra/modules/ecr/main.tf):

```hcl
"Keep last 10 tagged images" (tagPrefixList = ["sha-"], imageCountMoreThan = 10)
"Expire untagged images after 7 days"
```

Per-repository. A tier that gets skipped for many deploys keeps its last 10 successful images. Per-tier filtering reduces noise in repo histories rather than threatening retention.

## Plan

Five phases. Phase 1 is the structural change that unlocks everything else. Phases 2-3 do the SSM and Terraform fixups so per-tier divergence is safe. Phase 4 adds the operator escape hatch. Phase 5 polishes for first-deploy and edge cases.

Each phase is independently revertible. Phases 1 and 4 can ship together. Phases 2 and 3 need to land in the same PR (Terraform read change + SSM write change are coupled).

### Phase 1: Per-tier path filter and matrix

**Change.** Expand the `changed-paths` step in [`app.yml`](../../.github/workflows/app.yml) to compute per-tier change flags. Replace the unconditional `tiers` output from `compute-matrix` with a `changed_tiers` output that is the intersection of (in-scope matrix tiers for this environment) and (tiers whose inputs changed).

**Per-tier filter map.**

| Tier               | Filter paths                                                                                |
| ------------------ | ------------------------------------------------------------------------------------------- |
| `imap`             | `docker/imap/**`, `docker/shared/**`, `docker/templates/imap-sendmail.mc`, `docker/imap/Dockerfile` |
| `smtp-in`          | `docker/smtp-in/**`, `docker/shared/**`, `docker/templates/in-sendmail.mc`                  |
| `smtp-out`         | `docker/smtp-out/**`, `docker/shared/**`, `docker/templates/out-sendmail.mc`                |
| `sinkhole`         | `docker/sinkhole/**`                                                                        |
| monitoring tiers   | `docker/<tier>/**` only                                                                     |

All tiers additionally pick up changes to:
- `.github/workflows/app.yml`
- `.github/scripts/deploy-ecs-service.sh`

(These cause everything to rebuild because the workflow or deploy script changed - rare enough that broad invalidation is fine and explicit enough to surface in PR review.)

**Implementation.** Express the per-tier filters in [`dorny/paths-filter`](../../.github/workflows/app.yml) as separate filter keys (`docker_imap`, `docker_smtp_in`, `docker_smtp_out`, `docker_sinkhole`, `docker_<monitoring-tier>` for each). The resolve-areas step intersects with the in-scope matrix and emits `changed_tiers` as a JSON array. The `docker` job's matrix fans out over `changed_tiers` instead of `tiers`. The job's `if:` becomes `if: needs.setup.outputs.changed_tiers != '[]'`.

**Risk.** Filter drift. If a new shared script or template file lands and is not added to the per-tier filter map, changes to it will silently skip rebuilds of tiers that depend on it. Mitigations:
- Document the dependency graph at the top of [`app.yml`](../../.github/workflows/app.yml) so any new `COPY` in a Dockerfile prompts a matching filter update.
- Add a lightweight test in CI (a shell script under `.github/scripts/`) that parses `docker/*/Dockerfile`, extracts `COPY shared/...` and `COPY templates/...` lines, and verifies each referenced path is included in the corresponding tier's filter. Fail the workflow if the filter is out of date.

**Revert.** Single-commit revert of `app.yml`.

**Estimated savings.** Single-tier changes go from 3-12 builds to 1. Single-tier ECS rolls go from 3-12 to 1. The IMAP gap disappears entirely from non-IMAP changes.

### Phase 2: Per-tier SSM image-tag keys

**Change.** Move from one SSM parameter (`/cabal/deployed_image_tag`) to one per tier (`/cabal/deployed_image_tag/imap`, `/smtp-in`, `/smtp-out`, plus per-monitoring-tier as needed). Keep the legacy key as a *fallback* read for any tier whose per-tier key is missing (bootstrap path).

**Why.** Once tiers can diverge in tag, the canonical-IMAP read in [`refresh-ssm-from-running.sh`](../../.github/scripts/refresh-ssm-from-running.sh) silently corrupts the non-IMAP tier task-defs on a Terraform-driven topology change. The fix is to read each tier's running image and write each tier's key.

**Implementation.**

1. Rewrite `refresh-ssm-from-running.sh` to take an explicit `--all-tiers` flag (or default behaviour) that:
   - Lists all ECS services in `cabal-mail` matching `cabal-*`.
   - For each, reads the current image tag from the running task definition.
   - Writes `/cabal/deployed_image_tag/<tier>` with that value.
   - Preserves the legacy `/cabal/deployed_image_tag` (write the IMAP tier's value to it, for backward compat during the cutover).
2. Update [`terraform/infra/modules/ecs/locals.tf:34-45`](../../terraform/infra/modules/ecs/locals.tf) to read per-tier SSM data sources:
   ```hcl
   data "aws_ssm_parameter" "tier_image_tag" {
     for_each = local.tiers
     name     = "/cabal/deployed_image_tag/${each.key}"
   }
   ```
   And `tier_image[tier] = "${ecr_url}:${data.aws_ssm_parameter.tier_image_tag[tier].value}"`.
3. Keep the bootstrap sentinel (`bootstrap-placeholder`) behaviour: when the per-tier key resolves to the sentinel, fall back to the public-ECR placeholder image. Apply the same logic per-tier.

**Risk.** SSM parameter creation. The per-tier keys do not exist until first written. Two options:
- Pre-seed them in Terraform with the bootstrap sentinel value, same as the legacy key was handled, so they always resolve. This requires a small Terraform-managed `aws_ssm_parameter` per tier, with `lifecycle { ignore_changes = [value] }` so subsequent script writes are not overwritten.
- Or have `refresh-ssm-from-running.sh` create them on first write.

The Terraform-managed approach is cleaner: state is consistent, plan-time reads always succeed.

**Revert.** Reverting the locals.tf change re-pins all tiers to the legacy SSM key. The per-tier keys can remain in SSM with no consumer.

**Estimated savings.** None directly; this is the correctness fix that makes phase 1 safe long-term.

### Phase 3: Terraform plan-time read changes

**Change.** Anywhere [`terraform/infra/main.tf`](../../terraform/infra/main.tf) currently consumes `data.aws_ssm_parameter.deployed_image_tag.value` (lines 192, 218, 266 per the grep), introduce per-tier values. The ECS module already gets one image_tag input today; broaden the input to a map (`image_tags = { imap = "...", smtp-in = "...", ... }`) and let the module pick the right one per tier.

**Why.** Coupled to phase 2. Until Terraform reads per-tier, it cannot regenerate task-defs correctly on a topology change.

**Implementation.** Mechanical: add an `image_tags` map variable to the ECS module, wire each tier's task definition to `var.image_tags[tier]`, drop the singular `image_tag` (or keep as fallback). Same change for the sinkhole module and any other consumer.

The two non-ECS callers at [`main.tf:218,266`](../../terraform/infra/main.tf) (likely cloudwatch-exporter and monitoring stack) need similar per-tier treatment.

**Risk.** A topology-only apply in the gap between phase 2 and phase 3 reads the new per-tier SSM keys but the Terraform consumer still expects the old one. Land phases 2 and 3 in the same PR.

**Revert.** Roll the module input back to the singular tag, re-read the legacy SSM key.

**Estimated savings.** None directly; correctness for phase 1.

### Phase 4: Workflow override for forced rebuild

**Change.** Extend [`workflow_dispatch.inputs`](../../.github/workflows/app.yml) with a new optional input - one of:
- `force_tiers` (comma-separated tier list), or
- `force_all` (boolean) - simpler.

When set, the per-tier filter is bypassed and `changed_tiers` becomes the full in-scope matrix.

**Why.**
- First-time deploy to a fresh environment: nothing has been pushed yet, the per-tier filter has no baseline. A `workflow_dispatch areas=all force_all=true` covers this.
- Base-image refresh: when AL2023 ships a security update, the operator wants to rebuild all containers even though no `docker/**` file changed.
- Operator catchup after an aborted deploy: re-deploy everything regardless of what `git diff` says.

**Implementation.** Wire the input into the resolve-areas step; when true, override the per-tier filter outputs to all-true.

**Risk.** None.

**Revert.** Remove the input.

**Estimated savings.** None; this is the escape hatch that makes the rest safe.

### Phase 5: Bootstrap and edge cases

**Change.** Small fixups for the situations where per-tier filtering interacts badly with reality.

1. **First push to a new environment.** ECR repos exist (Terraform creates them) but have no images. The per-tier filter has no concept of "image is missing in ECR." Either:
   - Run a one-off `workflow_dispatch force_all=true` after the first Terraform apply. Document this in `docs/setup.md`.
   - Or have setup-job pre-check ECR for each in-scope tier and treat "no tag exists" as "this tier needs to build" regardless of path filter. More work; only matters for fresh environments which are rare.

   Recommendation: option 1, with a setup-doc note.

2. **PR branches.** Per-tier filtering on push events is already gated to the three named branches ([`app.yml:29-32`](../../.github/workflows/app.yml)). Other branches don't trigger the workflow at all, so no change needed.

3. **Workflow_dispatch with `areas=docker` but no `force_*`.** Resolves to "rebuild every tier in scope" because the filter step is push-only ([`app.yml:122-124`](../../.github/workflows/app.yml)). Keep this behaviour - matches today's mental model of "areas=docker means the whole docker area."

4. **`refresh-ssm-from-running.sh` idempotency.** Today the script runs at the start of Terraform plan. After phase 2, ensure it doesn't write a key if its value already matches what is in SSM (avoid no-op SSM history churn). `aws ssm put-parameter` is idempotent at the parameter level but counts toward versioning; a value-comparison short-circuit keeps the history clean.

**Risk.** None individually; these are polish.

**Revert.** Each fixup is independent.

**Estimated savings.** None; correctness and ergonomics.

## Combined estimated downtime and CI impact

| Scenario                              | Today                          | After plan                    |
| ------------------------------------- | ------------------------------ | ----------------------------- |
| Change `docker/imap/configs/...`      | 3-12 builds, 3-12 service rolls (incl. IMAP gap) | 1 build, 1 service roll (IMAP gap unavoidable; see [`imap-deploy-downtime-plan.md`](./imap-deploy-downtime-plan.md)) |
| Change `docker/smtp-in/...`           | 3-12 builds, 3-12 rolls incl. IMAP gap | 1 build, 1 roll, no IMAP gap |
| Change `docker/smtp-out/...`          | 3-12 builds, 3-12 rolls incl. IMAP gap | 1 build, 1 roll, no IMAP gap |
| Change `docker/shared/entrypoint.sh`  | 3-12 builds, 3-12 rolls incl. IMAP gap | 3 builds (core tiers), 3 rolls incl. IMAP gap |
| Change `docker/prometheus/...`        | 3-12 builds, 3-12 rolls incl. IMAP gap | 1 build, 1 roll, no IMAP gap |
| `workflow_dispatch force_all=true`    | (same as today)                | 3-12 builds, 3-12 rolls (intentional) |

The savings depend on commit shape. In the hot path (single-tier polish work), each deploy is ~3x faster (no monitoring) or ~12x faster (with monitoring), and most importantly does not cost an IMAP gap on changes that don't touch IMAP.

## Risks and rollback

Per phase above. Phase 1 alone, without phases 2-3, is **not safe** if Terraform ever regenerates a non-IMAP task-def while tiers are on divergent tags - the regenerated task-def would re-pin to the IMAP tier's tag. The safe land order is:

1. PR A: phases 2 + 3 together (per-tier SSM + Terraform reads). No behaviour change; both old singular and new per-tier keys are populated. The legacy SSM key keeps being maintained.
2. Soak in stage for at least a week. Verify per-tier SSM keys track running images correctly across a few real deploys.
3. PR B: phase 1 + phase 4 together (per-tier filter + workflow override). At this point unchanged tiers actually skip.
4. PR C: phase 5 polish.

If any phase regresses, revert that phase's PR. The legacy SSM key kept alive through phases 2-3 is the safety net: a full revert of phase 1 returns to today's "all tiers rebuild on any docker change" behaviour while the SSM model remains in the new shape, which is harmless.

## Interaction with the IMAP downtime plan

The two 0.10.x plans are independent and complementary:

- [`imap-deploy-downtime-plan.md`](./imap-deploy-downtime-plan.md) shortens the gap *when IMAP does roll*.
- This plan eliminates the IMAP gap *on changes that should not have caused it in the first place*.

Together they reduce the deploy-induced IMAP outage rate substantially: by the *width* of each roll (IMAP downtime plan) and by the *frequency* of rolls per change (this plan).

Either can ship first. The IMAP downtime plan's phases are container- and Terraform-flavoured; this plan's are workflow- and Terraform-flavoured. They touch different files and do not block each other.

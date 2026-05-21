# Lambda Layer Removal Plan

## Context

The shared Lambda layer at `lambda/api/python/` was introduced in early 0.x to avoid installing `imapclient` and `dnspython` redundantly across the API functions. It also became the home of the project's only first-party Lambda module, [`helper.py`](../../lambda/api/python/src/helper.py).

The 0.9.0 [build-deploy-simplification-plan.md](build-deploy-simplification-plan.md) cut Terraform out of the function-code deploy path: phases 2 and 3 added a `lifecycle { ignore_changes = [s3_key, s3_object_version, source_code_hash] }` clause to [`aws_lambda_function`](../../terraform/infra/modules/app/modules/call/lambda.tf:185) and routed deploys through `aws lambda update-function-code` in [`deploy-lambda-zip.sh`](../../.github/scripts/deploy-lambda-zip.sh). The plan never extended the same treatment to the layer. As a result:

- The layer's [Terraform module](../../terraform/infra/modules/lambda_layers/main.tf) still computes `source_code_hash` from the S3 sidecar at plan time and rotates `aws_lambda_layer_version` whenever the zip changes.
- Each consuming function's [`layers`](../../terraform/infra/modules/app/modules/call/lambda.tf:156) attribute is *not* in the lifecycle ignore list, so a new layer ARN is rebound by Terraform.
- [`app.yml`'s lambda-api deploy step](../../.github/workflows/app.yml:329) explicitly skips the `python/` directory (`case "${FUNC}" in python|healthchecks_iac) continue ;;`) because there is no Lambda function named `python` to update; it only uploads the zip.

Net effect: a layer-content change ships as far as S3 via `app.yml`, then sits there until the next `infra.yml` apply rotates the layer version and rebinds functions. This was rediscovered when [PR #347](https://github.com/cabalmail/cabal-infra/pull/347) fixed `helper.py` going missing from the layer build, [`6d357f14`](https://github.com/cabalmail/cabal-infra/commit/6d357f14) fixed it again after the 0.9.5 parallelisation regressed it, and the operator observed that running `app.yml` alone left the message-list endpoint broken until `infra.yml` ran too.

The layer is also small enough that bundling its contents per-function is no longer obviously expensive: `imapclient` + `six` is ~200 KB pip-installed, `dnspython` is ~280 KB, `helper.py` is ~4 KB, and only 16 of the 33 API functions need any of it. Bundling sidesteps the layer-version rebinding gap entirely and makes each function a self-contained deploy unit.

## Goals

- Each `lambda/api/<func>` function builds a self-contained zip that includes its own third-party deps and `helper.py` (when needed). No shared layer.
- A push to `lambda/api/<func>/**` deploys end-to-end via `app.yml` with no Terraform involvement, identical to the function-code path established in 0.9.0 phase 3.
- The `aws_lambda_layer_version`, the [`lambda_layers`](../../terraform/infra/modules/lambda_layers) module, and the `layer_arns` plumbing through `module.app` are deleted.
- `helper.py` lives at one canonical path and is copied into each consuming function's build at CI time, not duplicated in source.
- Each phase is independently mergeable and reversible.

## Non-goals

- Changing `helper.py`'s public interface or the set of API functions that consume it.
- Touching the Lambda runtime, Python version, or `boto3` (provided by Lambda).
- Migrating off zip-based Lambda deploys to container images.
- Reorganising the `lambda/api/<func>/` directory layout beyond the helper-source move.
- Per-function path-filtering inside `app.yml` (any `lambda/api/**` change still rebuilds and redeploys all api functions). That sits behind the simplification plan's open question and is orthogonal here.

## Current state (audit)

### What the layer contains

[`lambda/api/python/requirements.txt`](../../lambda/api/python/requirements.txt):

```
imapclient==2.3.1
dnspython==2.3.0
```

Plus [`lambda/api/python/src/helper.py`](../../lambda/api/python/src/helper.py) (4354 bytes, copied into `./python/` at build time per [`build-api-one.sh`](../../.github/scripts/build-api-one.sh)).

After build: `imapclient/`, `IMAPClient-2.3.1.dist-info/`, `dns/`, `dnspython-2.3.0.dist-info/`, `six.py`, `six-1.17.0.dist-info/`, `helper.py`. ~480 KB unzipped, ~200 KB zipped.

### What the consuming functions actually need

- **15 functions import `helper`** (and through it, `imapclient`): `delete_folder`, `fetch_attachment`, `fetch_inline_image`, `fetch_message`, `list_attachments`, `list_envelopes`, `list_folders`, `list_messages`, `move_messages`, `new_folder`, `revoke`, `send`, `set_flag`, `subscribe_folder`, `unsubscribe_folder`. Per-function need: `imapclient==2.3.1` + `helper.py`.
- **1 function imports `dns`**: `fetch_bimi`. Per-function need: `dnspython==2.3.0`.
- **17 functions need neither** (stdlib + boto3 only): `alert_sink`, `assign_address`, `backup_heartbeat`, `confirm_user`, `delete_user`, `disable_user`, `enable_user`, `get_preferences`, `healthchecks_iac`, `list`, `list_addresses_admin`, `list_dmarc_reports`, `list_users`, `new`, `new_address_admin`, `process_dmarc`, `set_preferences`, `unassign_address`. Their bundled zip stays the size it is today.

`process_dmarc` and `healthchecks_iac` carry a `layers = [var.layers["python"]]` attachment in [`dmarc.tf:106`](../../terraform/infra/modules/app/dmarc.tf:106) and inherit one through `module.call`, but neither imports anything from the layer; the attachment is dead weight today.

### Layer wiring in Terraform

```
terraform/infra/main.tf:45              module "lambda_layers"  (creates the layer)
terraform/infra/main.tf:84              layers = module.lambda_layers.layers       (passed to module.app)
terraform/infra/modules/app/variables.tf:5    variable "layers"                    (received by module.app)
terraform/infra/modules/app/main.tf:39        layer_arns = [var.layers["python"]]  (passed to module.call)
terraform/infra/modules/app/dmarc.tf:106      layers = [var.layers["python"]]      (process_dmarc, dead weight)
terraform/infra/modules/app/modules/call/variables.tf:9   variable "layer_arns"
terraform/infra/modules/app/modules/call/lambda.tf:156    layers = var.layer_arns  (every API function)
```

Total: one layer module, one input var on `module.app`, one input var on `module.call`, two attachments. `module.user_pool` has a stale `layers` mention in its [README](../../terraform/infra/modules/user_pool/README.md) but no actual wiring.

### CI/build wiring

- [`build-api.sh`](../../.github/scripts/build-api.sh) enumerates every dir under `lambda/api/` (including `python/`) and dispatches them in parallel through [`build-api-one.sh`](../../.github/scripts/build-api-one.sh).
- [`build-api-one.sh`](../../.github/scripts/build-api-one.sh) does `pip install --no-compile -r requirements.txt -t ./python` per function. For the layer dir, it also copies `./src/.` into `./python/` so `helper.py` ends up alongside the third-party deps. Today's per-function `requirements.txt` files are empty (the deps live only in the layer's `requirements.txt`).
- [`app.yml` lambda-api deploy](../../.github/workflows/app.yml:329) skips `python` and `healthchecks_iac` and calls `update-function-code` against every other directory.

## Target state

### Source layout

```
lambda/api/
  _shared/
    helper.py                        canonical first-party module
  fetch_bimi/
    function.py
    requirements.txt                  -> dnspython==2.3.0
  list_messages/
    function.py
    requirements.txt                  -> imapclient==2.3.1
  ...                                 (15 helper-using funcs same as list_messages)
  list/
    function.py
    requirements.txt                  -> empty
  ...                                 (17 stdlib-only funcs same as list)
```

`lambda/api/python/` is gone.

### Build flow (per function)

```
pushd <func>
rm -rf ./python
pip install --no-compile -r requirements.txt -t ./python
if grep -q '^from helper\|^import helper' function.py ; then
  cp ../_shared/helper.py ./python/helper.py
fi
... existing determinism steps ...
zip
```

The `grep` test is the same condition that selects which functions need `helper.py`; encoding it in the build script keeps the source tree clean (no checked-in copies of `helper.py`).

### Terraform

- `module "lambda_layers"` deleted from [`terraform/infra/main.tf`](../../terraform/infra/main.tf).
- The `layers` input on `module.app` and the `layer_arns` input on `module.call` deleted, along with both `layers = ...` lines in [`call/lambda.tf:156`](../../terraform/infra/modules/app/modules/call/lambda.tf:156) and [`dmarc.tf:106`](../../terraform/infra/modules/app/dmarc.tf:106).
- [`terraform/infra/modules/lambda_layers/`](../../terraform/infra/modules/lambda_layers) directory deleted.

### CI

- [`build-api.sh`](../../.github/scripts/build-api.sh) is unchanged in shape; it iterates every subdir of `lambda/api/`, but `python/` is no longer one of them.
- [`build-api-one.sh`](../../.github/scripts/build-api-one.sh) loses its `if [ -d ./src ]` branch and gains the `helper.py`-copy-from-`_shared` step.
- [`app.yml` lambda-api deploy](../../.github/workflows/app.yml:329) drops `python` from the skip list (only `healthchecks_iac` remains).

## Migration phases

### Phase 1: bundle deps per function (layer still attached)

- Move `helper.py` from `lambda/api/python/src/` to `lambda/api/_shared/` (or keep `python/src/` as canonical for this phase if the move complicates the diff). Build script copies it into each consuming function's `./python/` after `pip install`.
- Populate per-function `requirements.txt`: `imapclient==2.3.1` for the 15 helper-using funcs, `dnspython==2.3.0` for `fetch_bimi`, leave the rest empty.
- Update [`build-api-one.sh`](../../.github/scripts/build-api-one.sh) to copy `helper.py` into each consuming function's build (driven by the `grep` test above).
- The layer's own build path (`lambda/api/python/`) is unchanged; the layer continues to be published and attached to every function. Each consuming function's zip now contains a redundant copy of `helper.py` and `imapclient` (or `dnspython`).

Layer's `helper.py` and the bundled `helper.py` are byte-identical (same source file, same `cp -a`), so Lambda's `sys.path` resolution order between layer and bundle is irrelevant. The phase is a pure no-op at runtime.

Reversible: revert the commit. Bundled copies become inert; the layer continues to serve.

### Phase 2: detach the layer in Terraform

- Remove `layers = var.layer_arns` from [`call/lambda.tf:156`](../../terraform/infra/modules/app/modules/call/lambda.tf:156) and `layers = [var.layers["python"]]` from [`dmarc.tf:106`](../../terraform/infra/modules/app/dmarc.tf:106).
- Remove the corresponding `layer_arns` and `layers` input variables.
- Apply via [`infra.yml`](../../.github/workflows/infra.yml). Each Lambda update happens in-place; the function zips already contain everything they need from phase 1.

After this phase the layer still exists in AWS but is unused. Topology-only Terraform applies no longer touch the function.layers attribute.

Reversible: revert the commit and re-apply. The functions go back to layer-attached mode; their bundled zips remain harmless duplicates.

### Phase 3: delete the layer

- Delete the `module "lambda_layers"` block from [`main.tf`](../../terraform/infra/main.tf) and the [`lambda_layers/`](../../terraform/infra/modules/lambda_layers) directory.
- Delete `lambda/api/python/`. Update [`app.yml` lambda-api deploy](../../.github/workflows/app.yml:329) to drop `python` from the skip case.
- Update [`build-api-one.sh`](../../.github/scripts/build-api-one.sh) to drop the layer-source `if [ -d ./src ]` branch.
- Apply via `infra.yml`. Terraform destroys `aws_lambda_layer_version.layer["python"]` and the `aws_s3_object` data source. No function impact.
- Update the stale `layers` reference in [`user_pool/README.md`](../../terraform/infra/modules/user_pool/README.md).
- Update [`CLAUDE.md`](../../CLAUDE.md) to remove the `lambda_layers` module from the module table.

Reversible: revert and re-apply. Terraform recreates the layer version from S3; bundled function zips continue to work; the duplicate `helper.py` in each function bundle becomes dead weight again.

### Phase 4: cleanup

- Remove any remaining doc references to `module.lambda_layers` or the python layer in `docs/`.
- Audit [`docs/operations/runbooks/`](../../docs/operations/runbooks) for "layer version" troubleshooting that no longer applies.
- CHANGELOG entry under 0.9.x noting the simplification.

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Per-function pip install runs ~16 times in CI instead of once | High | Low | xargs -P parallelism is unchanged; pip wheel cache survives across runs; 17 functions have empty requirements and pay nothing. Expected wall-time delta: <30s |
| Per-function zip determinism regresses (different wheel binaries between runs) | Low | Medium | The `SOURCE_DATE_EPOCH`, `--no-compile`, `PYTHONDONTWRITEBYTECODE`, `__pycache__` purge, `direct_url.json` purge, chmod normalisation, and `LC_ALL=C sort` steps in [`build-api-one.sh`](../../.github/scripts/build-api-one.sh) already handle this for the layer build; same script governs the per-function builds |
| Phase 1 ships a function whose bundled `helper.py` drifts from the layer's `helper.py` | Low | High | Build script copies from a single source file; nothing is checked into per-function dirs; byte-identical guaranteed |
| Phase 2 apply removes the `layers` attribute but a still-running deployment package somehow lacks the deps | Low | High | Phase 1 must ship and bake on dev/stage before phase 2; smoke `list_messages` on stage between phases |
| Cold-start regression from larger bundles | Low | Low | imapclient is ~200 KB; cold-start delta is sub-millisecond. No measurable impact at this size |
| Phase 3 destroy of the layer races with an in-flight `app.yml` that built against the old layout | Low | Low | The `concurrency:` group on `infra.yml` is per-branch; phase 3's PR lands after phase 1's CI has fully drained, and `app.yml` after phase 3 builds the layer-less tree |

## Alternatives considered

- **Keep the layer; teach `app.yml` to publish layer versions and rebind functions out-of-band.** This was the most-natural extension of the 0.9.0 simplification - `aws lambda publish-layer-version` after build, then `aws lambda update-function-configuration --layers <new-arn>` against every consumer, plus add `layers` to the lifecycle ignore list and extend [`record-lambda-hashes.sh`](../../.github/scripts/record-lambda-hashes.sh) to pin the running layer version. Rejected as the primary path because it carries forward the layer-rebinding coordination problem (a layer change still has to update N functions atomically) and adds more CI script surface than the bundle approach removes Terraform surface. Worth keeping in mind as a fallback if the bundle approach hits a snag.

- **Make `helper.py` a published package on a private PyPI / CodeArtifact.** Rejected. Adds a separate artifact pipeline for one ~4 KB file. The build-time copy from `_shared/` achieves the same single-source-of-truth property with no infrastructure.

- **Check `helper.py` into every consuming function's directory.** Rejected. Drift risk; 15 copies to keep in sync.

- **Switch all API functions to container-image deploys.** Out of scope. Solves the layer-rebinding problem but at the cost of a new build path, ECR storage, and a different cold-start profile. Worth considering on its own merits, not as a means to remove a layer.

## Cutover and rollback

Each phase is independently revertible. Phase 1 is a pure CI/source change with no infra touch; phase 2 detaches the layer in-place via `infra.yml`; phase 3 destroys the layer resource. A rollback at any phase is `git revert` of the offending PR followed by the appropriate workflow re-run (`app.yml` for phase 1 / 3 CI changes, `infra.yml` for phase 2 / 3 Terraform changes).

The complete-rollback escape hatch is "revert all three phases and re-apply infra"; estimated time: 20 minutes. Because phase 1 establishes per-function zips that are sufficient on their own, phases 2 and 3 can soak on stage for one release cycle each before reaching prod.

## Open questions

- **`_shared/` vs keeping `lambda/api/python/src/` as the canonical home through phase 2.** The first is cleaner but expands the diff in phase 1. Decide before phase 1 PR.
- **Is there appetite to do this opportunistically alongside the next `imapclient` or `dnspython` version bump,** so the layer-version rotation is a side effect of a needed dep change rather than a no-op? Lower-risk timing.
- **Should `process_dmarc`'s dead `layers = [var.layers["python"]]` attachment be removed in phase 1 as a no-op tidy-up,** or rolled into phase 2 with the rest of the layer-detach work? Slight preference for the latter so phase 1 stays pure-CI.

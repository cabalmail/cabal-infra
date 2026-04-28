# IaC Quality Gates Plan

## Context

The `terraform.yml` workflow has run three Terraform-targeted scanners on every push to `terraform/infra/**` for years: Checkov (broad cloud-config policy), tflint (Terraform-specific lint + provider rules), and tfsec (security-focused HCL scanner). The intent at the time was sound: catch misconfigurations before they land. The execution has drifted in ways that mean today these scanners are mostly noise generators, not gates:

- **Checkov** runs with `soft_fail: true` ([`terraform.yml:71`](../../.github/workflows/terraform.yml:71)). The job always succeeds. Findings are visible only by reading the raw log of a successful workflow — no one does.
- **tfsec** runs with `soft_fail: false` ([`terraform.yml:97`](../../.github/workflows/terraform.yml:97)) and is a real gate. But tfsec itself was merged into [Trivy](https://github.com/aquasecurity/tfsec#tfsec-is-joining-the-trivy-family) in 2023 and the standalone project is in maintenance mode; the action we use (`aquasecurity/tfsec-action@v1.0.0`) is the same code under a deprecated wrapper.
- **tflint** runs but its loop is silently broken: `for i in ./ modules/* modules/*/modules/* ; do tflint ; done` ([`terraform.yml:91`](../../.github/workflows/terraform.yml:91)) never `cd`s into `$i`, so `tflint` is invoked N times in the same root directory and the modules are never scanned. The pinned AWS ruleset version in [`terraform/.tflint.hcl`](../../terraform/.tflint.hcl) is `0.20.0` — the current ruleset is at the 0.40 line.
- The `terraform/dns` (bootstrap) stack runs through [`bootstrap.yml`](../../.github/workflows/bootstrap.yml) and has **no scanners at all**.
- All three tools are loosely pinned: Checkov action at `@master`, tflint installer is `curl ... master/install_linux.sh`, tfsec action at `v1.0.0`. Gate strictness drifts silently as upstream ships new rules.

This plan does two separable things, in order:

1. **Replace tfsec with Trivy.** A like-for-like swap that costs us nothing and unblocks the rest of the work on a maintained tool.
2. **Convert all three scanners from background noise into staged quality gates.** Net-new findings fail CI; the existing pile is captured as a baseline and walked down deliberately.

The two halves can ship independently, but combining them in one rollout per stack keeps the operator-facing churn to a single inflection point.

## Goals

- Every PR that touches `terraform/infra/**` or `terraform/dns/**` runs Checkov, tflint, and Trivy IaC against both stacks. New findings fail the workflow.
- Each finding reachable in CI is either fixed, suppressed inline with a written justification, or in a checked-in baseline file with a recorded rationale and an owner.
- The baseline shrinks monotonically. CI fails if a baseline entry no longer matches a real finding (drift detection), and fails if a new finding appears that isn't in the baseline.
- Tool versions are pinned so the gate's strictness only changes by deliberate PR.
- Operators can run the same scans locally in under a minute against a clean checkout (`make scan` or equivalent), so feedback is reachable before pushing.
- The rollout is reversible at every step: any phase can be rolled back without re-doing prior phases.

## Non-goals

- Writing custom Rego/OPA policies for Cabalmail-specific rules. The three tools' built-in rule packs cover what we need at this scale; revisit if the rule set ever needs to express something org-specific (e.g. "no resource without a `cabal:owner` tag").
- Scanning the Lambda Python source (covered by `pylint` already), the React app (separate concern), or the Docker images. Container image scanning with Trivy is a natural follow-on but is a separate posture decision.
- SAST/DAST coverage of the running services. The scope here is *infrastructure-as-code* configuration only.
- Replacing Checkov or tflint. Both are actively maintained as of this writing and have non-overlapping coverage with each other and with Trivy.
- Forcing the bootstrap stack (`terraform/dns`) to use the *same* baseline file as `terraform/infra`. They get parallel-but-separate baselines.

## Tool currency assessment

| Tool     | Status                              | Verdict                                                                          |
| -------- | ----------------------------------- | -------------------------------------------------------------------------------- |
| Checkov  | Actively maintained by Prisma Cloud | **Keep.** Broadest rule pack; strong AWS coverage; supports baselining natively. |
| tflint   | Actively maintained                 | **Keep.** Only tool here that catches Terraform-language lint (unused vars, deprecated syntax, provider-arg shape). The AWS ruleset complements security scanners. |
| tfsec    | Merged into Trivy; maintenance mode | **Replace with Trivy IaC.** Same Aqua engine, same finding IDs (`AVD-AWS-*`), actively maintained, single binary that we can later reuse for image scanning. |

Other tools considered and rejected:

- **KICS (Checkmarx)** — viable, but rule overlap with Checkov is high and we'd be running two large policy engines for marginal coverage gain.
- **Snyk IaC** — commercial; the open-source seat we'd need is not justified at our scale.
- **terrascan (Tenable)** — has been less active than the alternatives; rule set lags Checkov.
- **OPA + Conftest** — most flexible, most work. Out of scope per non-goals; reconsider if/when org-specific rules emerge.

## Current state (audit)

- `terraform.yml` jobs: `chekov` (sic, the job name has a typo), `tflint`, `tfsec`. All three depend on `build` (which writes `backend.tf`) and feed into `apply` via `needs`. The `apply` job won't run if `tflint` or `tfsec` fails; Checkov is bypassed because of `soft_fail: true`.
- `bootstrap.yml`: `build → plan → apply`. No scanner jobs at all.
- No baseline files: `find . -maxdepth 4 -name '.checkov*' -o -name '.tfsec*'` is empty.
- No `Makefile` or developer-side runner for these scans.
- `.tflint.hcl` lives at [`terraform/.tflint.hcl`](../../terraform/.tflint.hcl) (one level above both stacks) and only enables the AWS plugin. No `terraform_*` rules, no `terraform_module_pinned_source`, no `terraform_required_version` enforcement.
- Workflow path triggers on `terraform.yml` are `terraform/infra` and `terraform/infra/*` and `terraform/infra/*/**`. The bootstrap stack would need a separate trigger or a unification.

A short investigation step to bake into Phase 0: collect a current finding count from each tool against the current `main` to set expectations for the size of the initial baseline.

## Target state

### Tool inventory (post-migration)

| Tool        | Action / Binary                                                          | Version pin                  | Scope                   |
| ----------- | ------------------------------------------------------------------------ | ---------------------------- | ----------------------- |
| Checkov     | `bridgecrewio/checkov-action@<sha>`                                      | Tagged release, by SHA       | both stacks             |
| tflint      | `terraform-linters/setup-tflint@<sha>` + `tflint --recursive`            | Tagged release, by SHA       | both stacks             |
| Trivy IaC   | `aquasecurity/trivy-action@<sha>` with `scan-type: config`               | Tagged release, by SHA       | both stacks             |

All three are pinned to commit SHA, not floating tags, per the standard supply-chain hardening posture for third-party actions. The Renovate/Dependabot rule (covered below) bumps these as a normal PR with clear diffs.

### tflint loop fix and config

Replace the broken loop with the supported `--recursive` flag (tflint 0.50+):

```yaml
- name: run-linter
  working-directory: ./terraform/infra
  run: tflint --recursive --format compact
```

Bump `.tflint.hcl` to current AWS ruleset and enable the bundled `terraform_*` rules:

```hcl
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.40.0"   # or whatever's latest at PR time
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

The `recommended` preset enables `terraform_required_version`, `terraform_module_pinned_source`, `terraform_unused_declarations`, and a handful of similar lints we should already be passing. If we're not, those become baseline entries.

### Baseline files (per tool, per stack)

Each tool gets a per-stack baseline checked into the stack root:

```
terraform/infra/.checkov.baseline
terraform/infra/.tflint.baseline      # or `.tflint-ignore` per project convention
terraform/infra/.trivy.baseline
terraform/dns/.checkov.baseline
terraform/dns/.tflint.baseline
terraform/dns/.trivy.baseline
```

Format: each tool's native baseline format. Checkov has `--create-baseline` / `--baseline`. Trivy has `--ignorefile .trivyignore` plus `misconfig.exceptions` in `trivy.yaml`. tflint emits a JSON-based ignore via `--format=json` plus an `--ignore-rule`/`--filter` mapping; the practical pattern is per-resource `# tflint-ignore: <rule_name> # justification` on the offending line (see "Suppressions" below).

The baseline files are first-class, reviewed artifacts. Each entry must include a one-line justification recorded either in the file itself (Checkov supports JSON metadata) or in a sibling `BASELINE.md` per stack (`terraform/infra/BASELINE.md`, `terraform/dns/BASELINE.md`) cross-referencing the IDs. The presence of a justification is verified by a small CI check (Phase 4).

### Suppressions in code

Inline suppressions are preferred over baseline entries when the finding is local to one resource and we genuinely don't intend to fix it:

- Checkov: `# checkov:skip=CKV_AWS_<n>: <one-sentence justification>`
- Trivy: `# trivy:ignore:AVD-AWS-<n> # <justification>`
- tflint: `# tflint-ignore: <rule_name> # <justification>`

A pre-commit + CI check rejects suppressions without a justification text after the colon/hash. Without that guard, the rationale-capture goal degrades into shrug-emoji silencing.

### Drift detection

Once baselines exist, the gate has two failure modes:

1. **New finding not in the baseline.** Standard fail-the-PR behaviour.
2. **Baseline entry that no longer matches any real finding** (stale entry — the underlying code was fixed but the entry was never removed). This drifts the baseline upward and re-creates the run-and-ignore problem we're solving.

Checkov has a `--baseline` mode but does not emit "stale entry" diagnostics out of the box. The pragmatic workaround: a small Python helper run after each scanner that diffs `current_findings ∪ inline_suppressions` against the baseline, fails if anything in the baseline is unaccounted for. Same pattern for Trivy and tflint. Lives in `.github/scripts/baseline-diff.py`.

### Rollout posture per finding class

Decisions to make per finding type, applied during the baselining phase:

- **High-severity, code-localised** (e.g. open security group, public S3 bucket, missing encryption-in-transit): **fix the code** in Phase 2.5 (below). These never enter the baseline.
- **High-severity, design-driven** (e.g. "no MFA delete on the state bucket" — we have controls upstream): inline-suppress with justification, *not* baseline.
- **Medium/low-severity, broad** (e.g. "tag X missing on Y resources"): baseline, with a tracking entry in the per-stack `BASELINE.md` and a target version to clear them by. These are the decay-candidates.
- **Tool-of-no-use** (e.g. Checkov rules that flag intentional architectural choices we'd never change): suppress *globally* in `.checkov.yaml` with a top-of-file rationale. Use sparingly.

The classification work happens in Phase 2; the actual code remediation for the first bucket happens in Phase 2.5; ongoing decay for the third bucket happens in Phase 4. This split keeps "establish what we have" and "fix what must be fixed before gating" as separate, individually-rollback-able phases — rather than bundling them into the gate-flip PR where a slip on either side blocks the other.

### CI: surfacing findings

Checkov, Trivy, and tflint can all emit SARIF; uploading SARIF via `github/codeql-action/upload-sarif` populates the GitHub **Security → Code scanning** tab with deduplicated, navigable findings tied to file lines. This replaces "scroll through job logs" as the operator's first stop and gives us deltas per PR for free.

PR comment posture: leave the SARIF surface as the canonical view; do *not* spam PRs with one-comment-per-finding bots. Optional: a single summary comment per PR with counts and a link to the Security tab.

### Local runner

A `Makefile` (or `.github/scripts/scan-local.sh`) at the repo root that runs all three tools against both stacks:

```make
.PHONY: scan scan-infra scan-dns
scan: scan-infra scan-dns
scan-infra:
	checkov -d terraform/infra --baseline terraform/infra/.checkov.baseline
	tflint --recursive --chdir terraform/infra
	trivy config terraform/infra --ignorefile terraform/infra/.trivy.baseline
scan-dns:
	checkov -d terraform/dns --baseline terraform/dns/.checkov.baseline
	tflint --chdir terraform/dns
	trivy config terraform/dns --ignorefile terraform/dns/.trivy.baseline
```

The point is parity between local and CI: if it passes locally, it passes in CI, and vice versa. Same tool versions via `mise`/`asdf`/`pre-commit-hooks`, picked at PR time.

## Migration sequence

One PR per phase. Each phase is independently deployable; each phase's rollback is the previous phase.

### Phase 0 — Baseline measurement (no behavioural change)

Run each tool against current `main` for both stacks; record the finding counts and severity breakdown in [`docs/0.9.0/iac-baseline-snapshot.md`](./iac-baseline-snapshot.md) (created as part of this phase). Output sets the size of the work in Phase 3 and lets us track decay.

This phase doesn't touch CI. Pure reconnaissance.

### Phase 1 — Replace tfsec with Trivy IaC, scan both stacks, still soft-fail

Single PR:

- Remove the `tfsec` job; add a `trivy` job using `aquasecurity/trivy-action@<sha>` with `scan-type: config` on `terraform/infra`.
- Add a parallel `trivy-dns` job (and `checkov-dns`, `tflint-dns`) that runs against `terraform/dns`. Wire it into `bootstrap.yml`'s `apply` `needs`.
- All scanners set to soft-fail in this phase (yes, including Trivy — we are *intentionally* relaxing the one current gate while we re-establish the baseline). This is the riskiest single moment in the rollout, in the sense that we lose the existing tfsec gate for the duration of Phases 1–3. Mitigation: keep this window short (one to two weeks), and the prior gate's coverage is preserved in the new tool's findings — they don't disappear, they just don't fail CI yet.
- Pin all three actions to commit SHA. Pin tflint AWS ruleset to a current version.
- Fix the broken tflint loop (use `--recursive`).
- Upload SARIF from each scanner to `github/codeql-action/upload-sarif`.

After this phase merges, the **Security → Code scanning** tab has a real findings list against current `main`. Phase 0's snapshot validates that the new Trivy findings are a superset of what tfsec reported (they should be; same engine, newer rules).

### Phase 2 — Establish baselines

Single PR per stack (so two PRs):

- Run each tool, generate the three baseline files (`.checkov.baseline`, `.tflint.baseline`, `.trivy.baseline`).
- Hand-edit each entry to include a justification — *do not bulk-import* without classifying. This is the hard, slow part of the work; expect a couple of focused review sessions per stack.
- Add the per-stack `BASELINE.md` cross-referencing IDs to one-paragraph rationales and target removal versions where applicable.
- Inline-suppress findings classified as "high-severity design-driven" per the rollout posture above.

The PR includes the baseline files but **CI is still soft-fail**. The baseline is established but not yet enforcing.

### Phase 2.5 — Fix sweep (high-severity, code-localised)

Not a single PR — a fan-out of small focused PRs, one per finding cluster, sized so that each is reviewable independently. The phase is bounded by classification (which findings are in scope) and by an exit criterion (all of them are landed or reclassified), not by calendar time.

The actual size of this phase is unknown until Phase 0's snapshot is in hand. The plausible range, given Cabalmail's footprint, is somewhere between five and forty fixes split across both stacks; the realistic calendar cost is one to four weeks of part-time work, dominated by review latency rather than implementation effort. **Do not promise a Phase 3 date until Phase 0 has reported.**

What lands in this phase:

- Encryption-in-transit / at-rest fixes on resources that should have them and don't.
- IAM tightening — wildcard actions, overly broad principals, missing condition keys.
- Logging gaps — buckets, ELBs, CloudFront distributions without access logs where the rule pack expects them.
- Public-access posture corrections.
- Anything else the Phase 2 classification put in the "code-localised must-fix" bucket.

What does *not* land in this phase:

- Findings reclassified during the work as "design-driven" — those move to inline suppressions in their own small PR.
- Findings deferred to decay — those stay in the baseline.
- Tool-rule disagreements — if a rule turns out to fight the architecture rather than flag a real issue, route to a global suppression in `.checkov.yaml` with rationale, not a code change.

Mid-phase classification corrections are fine and expected; the boundary between "fix" and "suppress" is sometimes only obvious once you've started writing the fix. What matters is that *every* high-severity finding from Phase 0 has either been fixed, suppressed-with-reason, or explicitly reclassified by the time Phase 3 starts.

Exit criterion (verifiable, not vibes-based): re-run all three scanners against the candidate Phase 3 branch; the count of HIGH/CRITICAL findings *not in the baseline and not inline-suppressed* is zero. This is the same check Phase 3's gate will perform, just run pre-flip so we know it passes.

If Phase 2.5 stretches past two calendar weeks without clear daylight, that is a signal that the severity threshold is wrong (too aggressive) or that some "code-localised" findings are actually design-driven and should be reclassified. Re-run the Phase 2 classification on the residual rather than grinding through.

### Phase 3 — Flip the gate

Single PR:

- Remove `soft_fail: true` from Checkov.
- Configure each scanner to use its baseline file. Trivy `--ignorefile`, Checkov `--baseline`, tflint inline `# tflint-ignore` is already in code from Phase 2.
- Add the `baseline-diff.py` drift-detection script and call it from each scanner job.
- Add the suppression-justification check (`grep`-class CI step that flags any `checkov:skip`, `trivy:ignore`, `tflint-ignore` comment without a `:` or `#` justification suffix).

After this phase, every new PR passes only if no new findings appear and no baseline entry has gone stale. The first PR after this lands is the test of whether the baseline + drift-detection setup is right; expect at least one false positive that needs a small fix to the diff script.

### Phase 4 — Decay

Ongoing, but with structure rather than vibes:

- Every baseline entry has a **target version** column in the per-stack `BASELINE.md` (e.g. "clear by 0.9.3"). Entries without a target version are treated as suppressions-disguised-as-baselines and reclassified.
- **Each release**, the release-prep checklist includes a step: "review baseline entries with target version ≤ this release; remove or push out with rationale." A push-out is a normal code-review decision, not a free pass.
- Once per quarter, bump tool versions (Checkov action, Trivy action, tflint AWS ruleset). Renovate/Dependabot can open these PRs automatically; a new finding from a new rule is then a normal PR-fail-or-baseline decision.
- Definition of done for the *whole* initiative — the point at which Phase 4 stops being a thing we track separately — is "baseline files contain only `medium`/`low` severity entries, total count is below an agreed-upon ceiling, and no entry is more than one minor version past its target." Pick the ceiling at the end of Phase 2 once the initial baseline size is known; encoding the number now would be guessing.

### Per-stack ordering

`terraform/dns` first through Phases 1–3 (it is small, has fewer findings, lower-stakes — DNS-only stack), then `terraform/infra`. The two stacks can share Phase 1 (single CI rewrite PR) but must split Phase 2 (one baseline PR per stack — they are different code).

### Rollback

| Phase | Rollback |
| ----- | -------- |
| 0     | None needed — pure measurement. |
| 1     | Revert the `terraform.yml` and `bootstrap.yml` changes. tfsec returns; trivy/checkov/tflint scope on dns disappears. |
| 2     | Delete the baseline files and `BASELINE.md`. CI continues to soft-fail (no behavioural change since Phase 1 was already soft-fail). |
| 2.5   | Each fix PR is independently revertable. Reverting them all returns the codebase to its Phase 2 state with the original baseline. Generally we wouldn't roll these back wholesale — the fixes are correctness improvements regardless of whether the gate flips. |
| 3     | Re-add `soft_fail: true` (or equivalent per tool) and remove the drift-detection step. The baseline files stay; gates revert to noise. |
| 4     | n/a (continuous). Individual tool-version bumps revert as normal PRs. |

The window of weakened security posture is Phase 1–3, during which tfsec's hard gate is gone but the new gates aren't yet enforcing. Bound this to ~2 weeks of calendar time and avoid scheduling it across a code-freeze or release-cut window.

## CI changes

- `.github/workflows/terraform.yml`: Trivy job replaces tfsec; Checkov and tflint pinned and corrected; SARIF uploads added; drift-detection step added in Phase 3.
- `.github/workflows/bootstrap.yml`: gain `checkov`, `tflint`, `trivy` jobs paralleling the infra workflow; `apply` gains `needs` on all three.
- `.github/scripts/baseline-diff.py`: new helper, one place per tool. Reads the tool's current JSON output, reads the baseline, diffs, exits non-zero on either "new finding not in baseline" or "baseline entry not in current findings."
- `.github/scripts/check-suppression-justifications.sh`: new helper, grep-based.
- `.github/dependabot.yml` (or Renovate config if we adopt it): pin-bump rules for `bridgecrewio/checkov-action`, `aquasecurity/trivy-action`, `terraform-linters/setup-tflint`, and the tflint AWS ruleset version inside `.tflint.hcl`.
- `Makefile` (new) or `.github/scripts/scan-local.sh`: local parity runner.

## Acceptance

- At Phase 3 entry, scanning the candidate branch reports zero HIGH/CRITICAL findings outside the baseline and inline-suppression set. (Phase 2.5 exit criterion, restated.)
- A PR introducing a new public-read S3 bucket or a wildcard IAM policy fails CI on at least one of the three scanners, with the failure linked from the PR's checks tab to a SARIF entry on the offending line.
- A PR removing a baseline entry whose finding still exists fails on the drift detector with a message naming the missing entry and the tool that found it.
- A PR fixing a baseline-listed finding without removing the baseline entry fails on the drift detector with a "stale baseline entry" message.
- The number of suppressions and baseline entries trends down release-over-release; the per-stack `BASELINE.md` shows decreasing row counts at each tagged release through 1.0.0.
- A clean local checkout with `mise` (or whatever we standardise on) installed runs `make scan` in under 60 seconds and produces the same pass/fail verdict as CI for the same revision.
- The Security → Code scanning tab on GitHub shows a deduplicated, navigable view of all open findings, partitioned by tool and severity.

## Open questions

- **Which tflint baseline format do we standardise on?** tflint's first-class story is in-code `# tflint-ignore` comments rather than a baseline file. For findings on generated code or where we don't want comment churn, we may need a JSON wrapper around `tflint --format json` filtered by a checked-in allowlist. Decide during Phase 2.
- **Severity threshold for fail vs. warn.** Trivy supports `--severity HIGH,CRITICAL`. Do we let MEDIUM findings through silently, baseline them, or fail on them? Recommendation: fail on all severities for the gate to work as a *hygiene* tool, not just a security tripwire — but acknowledge this widens the Phase 2 baseline considerably. Revisit after Phase 0's snapshot.
- **PR-comment bot vs. Security tab only.** The plan above defaults to Security tab only. If contributors aren't checking it, a single summary comment per PR is a small lift. Defer until we have evidence one way or the other.
- **Container image scanning.** Trivy is already on the runner once we adopt it; turning on `trivy image` against the three docker tier images is a follow-on with its own findings/baseline cycle. Not in scope here, but worth flagging to schedule for 0.9.x once IaC gates have soaked.
- **Pre-commit hooks.** A pre-commit config would catch findings before push for contributors who opt in. Optional polish; not gating.
- **Phase 2.5 sizing.** Will only become knowable after Phase 0's snapshot. If the HIGH/CRITICAL count comes back in the hundreds rather than the dozens, this plan needs a re-think — likely splitting Phase 2.5 across multiple 0.9.x point releases rather than treating it as a single pre-gate phase, and accepting that the gate flips later.

## Out of scope for 0.9.0

- Custom Rego/OPA policies for org-specific rules.
- Container image vulnerability scanning (separate posture pass).
- Lambda Python source security scanning beyond the existing pylint (Bandit/Semgrep is a separate decision).
- React app dependency scanning (`npm audit` / Dependabot already cover this).
- Automated remediation (Bridgecrew Yor-style auto-tagging, Snyk auto-fix PRs). Manual remediation only.

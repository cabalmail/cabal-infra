# Local IaC scan runner - parity with the scanner jobs in
# .github/workflows/infra.yml (docs/0.10.x/iac-quality-gates-plan.md).
#
# Runs Checkov, tflint, and Trivy against both Terraform stacks using the
# same invocations and the same shared tflint config (terraform/.tflint.hcl)
# that CI uses, against the same committed source CI scans. Use it to see
# findings before pushing.
#
# The per-stack CMK suppression (.checkov.yaml) and baselines
# (.checkov.baseline / .trivyignore) are wired in below, so a run reports
# only the *residual* - new findings not yet accepted. As of Phase 3 this is
# a real gate: any residual finding makes the command (and `make scan`) exit
# non-zero, the same verdict CI produces. A clean tree exits 0. To accept a
# new finding, fix it or add it to the stack's baseline/ignore with a
# BASELINE.md rationale - never silence `make scan` itself.
#
# Requires checkov, tflint, and trivy on PATH. IMPORTANT: install checkov via
# pipx (or pip), NOT brew - brew's checkov omits the graph (CKV2_*) checks, so
# it silently under-reports and its baseline disagrees with CI (this broke the
# gate's first live run). The checkov-graph-guard target fails fast if the
# checkov on PATH cannot run graph checks.
#   pipx install checkov==3.2.530
#   brew install trivy terraform-linters/tap/tflint

# tflint does not search parent directories for config; point it at the
# shared file with an absolute path (required because --recursive lints
# each module subdirectory in turn).
export TFLINT_CONFIG_FILE := $(CURDIR)/terraform/.tflint.hcl

.PHONY: scan scan-infra scan-dns tflint-init drift checkov-graph-guard

# DNS first (small, clean), then infra - mirrors the plan's per-stack order.
scan: scan-dns scan-infra

# Install the tflint plugins named in terraform/.tflint.hcl. No-op once
# they are present, so it is cheap to depend on from every scan target.
tflint-init:
	tflint --init

# Fail fast if the checkov on PATH cannot run graph (CKV2_*) checks - brew's
# build omits them, so it would produce a baseline that disagrees with CI.
# Probe the dns stack, which reliably trips CKV2_AWS_38/39.
checkov-graph-guard:
	@checkov -d terraform/dns --compact --quiet -o json 2>/dev/null | grep -q 'CKV2_' \
	  || { echo "ERROR: checkov on PATH is not running graph (CKV2_*) checks; it will disagree with CI."; \
	       echo "Install via pipx, not brew:  pipx install checkov==3.2.530"; exit 1; }

scan-dns: tflint-init checkov-graph-guard
	checkov -d terraform/dns --config-file terraform/dns/.checkov.yaml --baseline terraform/dns/.checkov.baseline --quiet --compact
	tflint --chdir=terraform/dns --recursive
	trivy config terraform/dns --ignorefile terraform/dns/.trivyignore --exit-code 1
	./.github/scripts/check-suppression-justifications.sh terraform/dns
	./.github/scripts/check-iam-resource-scope.py terraform/dns

scan-infra: tflint-init checkov-graph-guard
	checkov -d terraform/infra --config-file terraform/infra/.checkov.yaml --baseline terraform/infra/.checkov.baseline --quiet --compact
	tflint --chdir=terraform/infra --recursive
	trivy config terraform/infra --ignorefile terraform/infra/.trivyignore --exit-code 1
	./.github/scripts/check-suppression-justifications.sh terraform/infra
	./.github/scripts/check-iam-resource-scope.py terraform/infra

# Drift: fail if a baseline / ignore entry no longer matches a finding (stale).
# CI runs this inside the scanner jobs; run it locally when editing baselines.
drift: checkov-graph-guard
	checkov -d terraform/dns --config-file terraform/dns/.checkov.yaml --soft-fail --quiet --compact -o json > /tmp/cabal-ck-dns.json && python3 .github/scripts/baseline-diff.py checkov /tmp/cabal-ck-dns.json terraform/dns/.checkov.baseline
	trivy config terraform/dns --format json --quiet > /tmp/cabal-tv-dns.json && python3 .github/scripts/baseline-diff.py trivy /tmp/cabal-tv-dns.json terraform/dns/.trivyignore
	checkov -d terraform/infra --config-file terraform/infra/.checkov.yaml --soft-fail --quiet --compact -o json > /tmp/cabal-ck-infra.json && python3 .github/scripts/baseline-diff.py checkov /tmp/cabal-ck-infra.json terraform/infra/.checkov.baseline
	trivy config terraform/infra --format json --quiet > /tmp/cabal-tv-infra.json && python3 .github/scripts/baseline-diff.py trivy /tmp/cabal-tv-infra.json terraform/infra/.trivyignore

# --- Release / changelog ---------------------------------------------------
# changelog: collate changelog.d/ fragments into a dated CHANGELOG.md section.
# promote:   do that, then commit on stage, push, and open the stage->main PR.
# Pass the version (or a bump keyword) via VERSION=:
#   make changelog VERSION=0.10.14
#   make promote   VERSION=0.10.14      # also: patch / minor / major
# See docs/releasing.md.
.PHONY: changelog promote

changelog:
	@test -n "$(VERSION)" || { echo "usage: make changelog VERSION=<x.y.z>"; exit 1; }
	./scripts/collate-changelog.sh "$(VERSION)"

promote:
	@test -n "$(VERSION)" || { echo "usage: make promote VERSION=<x.y.z|patch|minor|major>"; exit 1; }
	./scripts/promote.sh "$(VERSION)"

# --- Apple client (local parity with apple.yml) ----------------------------
# Thin wrappers over scripts/build-apple.sh so a local "does it build?" check
# is as discoverable as `make scan`. The script mirrors the apple.yml CI
# invocations (xcodegen generate, swiftlint --strict, xcodebuild per platform)
# and carries the Xcode-select / arch caveats - see its header. macOS + full
# Xcode only; deliberately not folded into any aggregate target.
#   make apple            # generate + lint + build macos/ios/visionos (all)
#   make apple-lint       # swiftlint --strict only
#   make apple-kit-test   # xcodebuild test for CabalmailKit
.PHONY: apple apple-lint apple-macos apple-ios apple-visionos apple-kit-test

apple:          ; ./scripts/build-apple.sh all
apple-lint:     ; ./scripts/build-apple.sh lint
apple-macos:    ; ./scripts/build-apple.sh macos
apple-ios:      ; ./scripts/build-apple.sh ios
apple-visionos: ; ./scripts/build-apple.sh visionos
apple-kit-test: ; ./scripts/build-apple.sh kit-test

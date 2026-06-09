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
# Requires checkov, tflint, and trivy on PATH. On macOS:
#   brew install checkov trivy terraform-linters/tap/tflint

# tflint does not search parent directories for config; point it at the
# shared file with an absolute path (required because --recursive lints
# each module subdirectory in turn).
export TFLINT_CONFIG_FILE := $(CURDIR)/terraform/.tflint.hcl

.PHONY: scan scan-infra scan-dns tflint-init drift

# DNS first (small, clean), then infra - mirrors the plan's per-stack order.
scan: scan-dns scan-infra

# Install the tflint plugins named in terraform/.tflint.hcl. No-op once
# they are present, so it is cheap to depend on from every scan target.
tflint-init:
	tflint --init

scan-dns: tflint-init
	checkov -d terraform/dns --config-file terraform/dns/.checkov.yaml --baseline terraform/dns/.checkov.baseline --quiet --compact
	tflint --chdir=terraform/dns --recursive
	trivy config terraform/dns --ignorefile terraform/dns/.trivyignore --exit-code 1
	./.github/scripts/check-suppression-justifications.sh terraform/dns

scan-infra: tflint-init
	checkov -d terraform/infra --config-file terraform/infra/.checkov.yaml --baseline terraform/infra/.checkov.baseline --quiet --compact
	tflint --chdir=terraform/infra --recursive
	trivy config terraform/infra --ignorefile terraform/infra/.trivyignore --exit-code 1
	./.github/scripts/check-suppression-justifications.sh terraform/infra

# Drift: fail if a baseline / ignore entry no longer matches a finding (stale).
# CI runs this inside the scanner jobs; run it locally when editing baselines.
drift:
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
	./.github/scripts/collate-changelog.sh "$(VERSION)"

promote:
	@test -n "$(VERSION)" || { echo "usage: make promote VERSION=<x.y.z|patch|minor|major>"; exit 1; }
	./.github/scripts/promote.sh "$(VERSION)"

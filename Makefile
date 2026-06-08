# Local IaC scan runner - parity with the scanner jobs in
# .github/workflows/infra.yml (docs/0.10.x/iac-quality-gates-plan.md).
#
# Runs Checkov, tflint, and Trivy against both Terraform stacks using the
# same invocations and the same shared tflint config (terraform/.tflint.hcl)
# that CI uses, against the same committed source CI scans. Use it to see
# findings before pushing.
#
# Phase 2: the per-stack CMK suppression (.checkov.yaml) and baselines
# (.checkov.baseline / .trivyignore) are wired in below, so a clean run
# shows only the *residual* - i.e. new findings not yet accepted. Checkov
# and Trivy residuals are 0; tflint still reports its 6 warnings (slated to
# be fixed outright in Phase 2.5, so they are not baselined).
#
# Every command is still prefixed with `-` (make ignores the exit code) so
# the run exits 0, matching the soft-fail CI of Phases 1-2. When the gate
# flips (Phase 3), drop the `-` prefixes so `make scan` produces the same
# pass/fail verdict as CI.
#
# Requires checkov, tflint, and trivy on PATH. On macOS:
#   brew install checkov trivy terraform-linters/tap/tflint

# tflint does not search parent directories for config; point it at the
# shared file with an absolute path (required because --recursive lints
# each module subdirectory in turn).
export TFLINT_CONFIG_FILE := $(CURDIR)/terraform/.tflint.hcl

.PHONY: scan scan-infra scan-dns tflint-init

# DNS first (small, clean), then infra - mirrors the plan's per-stack order.
scan: scan-dns scan-infra

# Install the tflint plugins named in terraform/.tflint.hcl. No-op once
# they are present, so it is cheap to depend on from every scan target.
tflint-init:
	tflint --init

scan-dns: tflint-init
	-checkov -d terraform/dns --config-file terraform/dns/.checkov.yaml --baseline terraform/dns/.checkov.baseline --quiet --compact
	-tflint --chdir=terraform/dns --recursive
	-trivy config terraform/dns --ignorefile terraform/dns/.trivyignore

scan-infra: tflint-init
	-checkov -d terraform/infra --config-file terraform/infra/.checkov.yaml --baseline terraform/infra/.checkov.baseline --quiet --compact
	-tflint --chdir=terraform/infra --recursive
	-trivy config terraform/infra --ignorefile terraform/infra/.trivyignore

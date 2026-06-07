# Local IaC scan runner - parity with the scanner jobs in
# .github/workflows/infra.yml (Phase 1 of
# docs/0.10.x/iac-quality-gates-plan.md).
#
# Runs Checkov, tflint, and Trivy against both Terraform stacks using the
# same invocations and the same shared tflint config (terraform/.tflint.hcl)
# that CI uses, against the same committed source CI scans. Use it to see
# findings before pushing.
#
# Phase 1 has no baseline files yet, so every command is prefixed with `-`
# (make ignores the exit code): the run surfaces all findings and always
# exits 0, matching the soft-fail CI verdict. When the gate flips (Phase 3),
# drop the `-` prefixes and add the per-stack --baseline / --ignorefile
# flags so `make scan` produces the same pass/fail verdict as CI.
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
	-checkov -d terraform/dns --framework terraform --quiet --compact
	-tflint --chdir=terraform/dns --recursive
	-trivy config terraform/dns

scan-infra: tflint-init
	-checkov -d terraform/infra --framework terraform --quiet --compact
	-tflint --chdir=terraform/infra --recursive
	-trivy config terraform/infra

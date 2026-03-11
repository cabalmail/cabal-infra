# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-03-15

### Added

- Terraform module `terraform/infra/modules/ecs/` — ECS cluster with three services (IMAP, SMTP-IN, SMTP-OUT), task definitions, auto-scaling, capacity provider, Cloud Map service discovery, and all associated IAM roles
- Terraform module `terraform/infra/modules/ecr/` — container image repositories for the three mail services
- Docker images and scripts — three Dockerfiles (`imap`, `smtp-in`, `smtp-out`), shared entrypoint/reconfiguration/user-sync scripts, supervisord configs, Dovecot/sendmail/OpenDKIM configs, PAM auth integration, and sendmail `.mc` templates
- Documentation `docs/0.4.0/containerization-plan.md` — detailed migration plan documenting the containerization strategy
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

## Changelog: `main` → `0.4.0`

**142 files changed, 729 insertions, 5,631 deletions** — a major architectural shift from EC2/Chef-managed mail servers to ECS containerization, with Lambda runtime upgrades and infrastructure modernization.

---

### Architecture: ECS Containerization of Mail Services

The headline change is the **introduction of Docker/ECS-based mail infrastructure**, replacing EC2 instances managed by Chef with containerized services orchestrated by ECS.

- **New `terraform/infra/modules/ecs/`** (12 files, ~1,050 lines) — ECS cluster with three services (IMAP, SMTP-IN, SMTP-OUT), task definitions, auto-scaling, capacity provider, Cloud Map service discovery, and all associated IAM roles
- **New `terraform/infra/modules/ecr/`** — container image repositories for the three mail services
- **New Docker images and scripts** (35 files, 1,234 lines) — three Dockerfiles (`imap`, `smtp-in`, `smtp-out`), shared entrypoint/reconfiguration/user-sync scripts, supervisord configs, Dovecot/sendmail/OpenDKIM configs, PAM auth integration, and sendmail `.mc` templates
- **New `docs/0.4.0/containerization-plan.md`** (2,480 lines) — detailed migration plan documenting the containerization strategy
- **Removed `docker/todo.txt`** — planning document superseded by actual implementation

### Architecture: SNS/SQS Fan-Out for Configuration Triggers

- **Replaced SSM `SendCommand`** (targeting EC2 instances) with **SNS/SQS fan-out** for notifying containers of address changes
- Added `address_changed_topic_arn` to all API Lambda functions
- Added `sns:Publish` IAM permissions to Lambda execution roles
- Removed `ssm:SendCommand` and `ssm:StartSession` permissions (no longer targeting EC2 directly)
- `assign_osid` Lambda: removed SSM permissions, added `ecs:UpdateService` permission to trigger redeployments

### Lambda: Node.js → Python Migration

Three API functions and the Cognito post-confirmation trigger were rewritten from Node.js to Python:

- **`list`** — rewritten from `lambda/api/node/list/index.js` to Python
- **`new`** — rewritten from `lambda/api/node/new/index.js` to Python
- **`revoke`** — rewritten from `lambda/api/node/revoke/index.js` to Python, now includes proper authorization checks (`user_authorized_for_sender`) and shared-subdomain safety checks
- **`assign_osid`** (counter) — rewritten from Node.js to Python, now triggers ECS redeployments instead of Chef via SSM
- **Added `lambda/api/new_address/function.py`** — new function with DKIM key generation

**Directory restructuring:** Python Lambda functions moved from `lambda/api/python/` to `lambda/api/` (cleaner layout now that Node.js versions are removed).

### Lambda: Runtime & Layer Upgrades

- Python Lambda layer runtime upgraded from `python3.9` to `python3.13`
- Removed Node.js Lambda layer (no longer needed)
- Lambda functions no longer carry a `type` field — all are Python with a unified layer and handler
- Added S3 pre-flight checks that gate layer/function creation on zip existence

### Terraform: Cross-Stack Data Sharing

- **SSM Parameter Store replaced with remote state** — the `infra` stack now reads zone data via `terraform_remote_state` from the `dns` stack instead of SSM parameters (`/cabal/control_domain_zone_id`, `/cabal/control_domain_zone_name`)

### Terraform: Load Balancer Updates

- All four NLB listeners (IMAP/143, relay/25, submission/465, STARTTLS/587) now include ECS cutover conditionals, allowing gradual traffic migration from ASG to ECS target groups
- Added private DNS records for Cloud Map service discovery
- Added `nlb_arn` output

### Terraform: Miscellaneous

- **S3 bucket hardening** — explicit `acl = "private"` on cache and React app buckets
- **Backup vault** — `prevent_destroy` changed from `true` to `false` (flexibility during active development)
- **Added `terraform/infra/modules/vpc/ROLLBACK.md`** — NAT instance migration rollback instructions
- **DNS module** — added `locals.tf` with CI/CD build workflow metadata

### CI/CD (GitHub Actions)

- **New workflow:** `docker_build_push.yml` for building and pushing Docker images
- **Removed:** `lambda_api_node.yml` and `build-api-node.sh` (Node.js Lambda no longer needed)
- **Renamed:** `build-api-python.sh` → `build-api.sh` (Python is now the sole Lambda runtime)
- **Counter build script:** converted from Node.js npm to Python pip packaging
- **Terraform workflow:** added `image_tag` input and SSM update step for Docker image deployments
- **React workflow:** upgraded `actions/upload-artifact` and `actions/download-artifact` from v3 to v4
- **Counter workflow:** added pylint step for Python linting

### React App

No changes between `main` and `0.4.0` — all React changes were incorporated prior to this diff.

### Chef

- Minor whitespace formatting change in `dovecot-15-mailboxes.conf` (no behavioral impact)

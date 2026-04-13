# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.1] - 2026-04-13

### Added

- Terraform module `terraform/infra/modules/certbot_renewal/` — container-image Lambda on EventBridge schedule (every 60 days) that runs certbot with `certbot-dns-route53`, writes certs to SSM, and forces ECS redeployments, replacing the ACME Terraform provider
- `lambda/certbot-renewal/` — Dockerfile and Python handler for the certbot renewal Lambda (arm64)
- React contexts: `AuthContext` and `AppMessageContext` to replace prop drilling for auth state and toast notifications
- React hook: `useApi` — centralizes `ApiClient` instantiation using auth context
- `ErrorBoundary` component wrapping Email, Addresses, and Folders views with fallback UI
- Code splitting with `React.lazy` + `Suspense` for Email, Folders, and Addresses views
- Dual Rich Text / Markdown editing modes in the compose editor
- Unit tests for React components (`AppMessage`, `Nav`, `Login`, `SignUp`, `ComposeOverlay`, `MessageOverlay`, `Envelopes`, `Messages`, `ErrorBoundary`)
- Vitest + jsdom test runner for React app
- ENI trunking for ECS (`awsvpcTrunking` account setting, `ECS_ENABLE_TASK_ENI` agent config, managed policy attachment) to support `awsvpc` tasks on Graviton instances
- IMDSv2 hop limit increased to 2 on ECS launch template for container metadata access
- Documentation: `docs/0.4.1/react-modernization-plan.md`, `docs/unreleased/sendmail-replacement.md`

### Fixed

- NAT instance iptables rules lost on reboot — replaced nested heredoc (which created an empty systemd unit file) with `printf`-based generation
- Sendmail crash loop on `smtp-out` caused by orphan daemon holding port 25 — added `sendmail-wrapper.sh` with PID file cleanup and supervisord retry configuration
- `this.stage` typo in `MessageOverlay/index.js`
- Nav layout: scoped absolute positioning to logout button only
- Race condition in `Envelopes` where multiple async `getEnvelopes` calls could overwrite pagination state
- Sequential `setState` calls in `MessageOverlay` that could overwrite each other
- Memory leak risk from timers in `Messages` — consolidated 5 timer IDs into properly cleaned-up effects
- JWT token security: moved from `localStorage` to module-level memory variable (no longer persisted to disk)
- `App.jsx` `setState` override no longer serializes password to `localStorage`
- `App.jsx` message toast timer leak — stale `setTimeout` could fire after unmount; now tracked in a ref and cleared properly
- Compose toolbar button alignment and formatting issues

### Changed

- **ECS architecture migrated from x86_64 to ARM64 (Graviton)** — AMI filter changed from `amzn2-ami-ecs-hvm` (x86_64) to `al2023-ami-ecs-hvm` (arm64); instance type changed from T3/T4g to M6g
- **React upgraded from 17 to 18** — `ReactDOM.render` replaced with `createRoot`, Strict Mode enabled
- **React build tooling migrated from Create React App to Vite** — new `vite.config.js`, `index.html` moved to root, scripts updated to `vite`/`vitest`, output directory changed from `build/` to `dist/`
- **All React components converted from class-based to functional** with hooks (`useState`, `useEffect`, `useRef`, `useContext`, `useCallback`)
- **Compose editor replaced**: draft-js (abandoned) replaced with TipTap — native HTML support, toolbar with formatting/lists/alignment/color/links, heading levels 1-4, rich text paste preservation
- CSS Modules migration — `AppMessage.css`, `Login.css`, `SignUp.css`, `Folders.css` renamed to `.module.css` with scoped `styles.className` imports
- React CI workflow (`.github/workflows/react.yml`) — switched from `yarn` to `npm`, updated build commands and artifact paths for Vite
- Docker CI workflow (`.github/workflows/docker.yml`) — added `certbot-renewal` to build matrix, uses native arm64 runner, pushes `:latest` tag for certbot image
- `App.jsx` converted from class to functional component — uses hooks, functional state updates, separated transient UI state (message/error/hideMessage) from persisted app state
- All React `.js` component files renamed to `.jsx`
- Cloud Map namespace renamed from `cabal.local` to `cabal.internal`
- `docs/0.4.1/user-management-plan.md` moved to `docs/0.5.0/` (deferred to next release)

### Removed

- **Chef/EC2 infrastructure decommissioned (Phase 7 cutover complete):**
  - `chef/` directory — entire Chef cookbook (recipes, templates, libraries, resources)
  - `.github/workflows/cookbook.yml` — cookbook build and S3 upload workflow
  - `terraform/infra/modules/asg/` — Auto Scaling Group module (launch templates, IAM instance profiles, security groups, userdata)
  - `cabal_chef_document` SSM document and its output/variable plumbing (`modules/app/ssm.tf`, `modules/user_pool/variables.tf`)
  - `lambda/counter/node/` — legacy Node.js counter Lambda that invoked Chef via SSM (replaced by Python version in 0.4.0)
  - Instance-type NLB target groups and conditional listener routing in `modules/elb/` — listeners now forward directly to ECS target groups
  - `chef_license`, `imap_scale`, `smtpin_scale`, `smtpout_scale` variables and their CI/CD tfvars wiring
- `terraform/infra/modules/cert/acme.tf` — ACME/Let's Encrypt Terraform provider approach (replaced by certbot Lambda)
- `acme` and `tls` provider requirements from `terraform/infra/modules/cert/versions.tf`
- `prod` and `email` variables from cert module (only used by ACME)
- `draft-js`, `react-draft-wysiwyg`, `draftjs-to-html`, `html-to-draftjs`, `markdown-draft-js` — 5 packages replaced by TipTap
- `yarn.lock` (switched to npm/`package-lock.json`)
- `.github/scripts/react-documentation.sh` and `react-docgen`-generated docs (`react/admin/docs/`)
- Unused React dependencies: `react-lazyload`, `react-docgen`
- `greet_pause` from `smtp-out` sendmail template

## [0.4.0] - 2026-03-15

### Added

- Documentation `docs/0.4.0/containerization-plan.md` — detailed migration plan documenting the containerization strategy
- Terraform module `terraform/infra/modules/ecs/` — ECS cluster with three services (IMAP, SMTP-IN, SMTP-OUT), task definitions, auto-scaling, capacity provider, Cloud Map service discovery, and all associated IAM roles
- Terraform module `terraform/infra/modules/ecr/` — container image repositories for the three mail services
- Docker images and scripts — three Dockerfiles (`imap`, `smtp-in`, `smtp-out`), shared entrypoint/reconfiguration/user-sync scripts, supervisord configs, Dovecot/sendmail/OpenDKIM configs, PAM auth integration, and sendmail `.mc` templates
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
- ACME/Let's Encrypt certificate will be removed in 0.4.1

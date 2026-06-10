# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Cabalmail is a self-hosted email system running on AWS. This repository contains all infrastructure, server configuration, and the admin web app. The system provides three mail tiers — IMAP (mailbox access), SMTP-IN (inbound relay), and SMTP-OUT (outbound submission with DKIM signing) — backed by Cognito authentication, DynamoDB address storage, and EFS-based mailstores.

The mail tiers run as Docker containers on ECS (EC2 launch type). See `docs/0.4.0/containerization-plan.md` for the migration plan from the previous Chef/EC2 architecture.

## Development Process

These rules are evolving — they reflect the current solo-developer workflow and will change as patterns settle. Update them rather than working around them.

### Branches and environments

Three named branches map 1:1 to GitHub Environments and AWS accounts:

| Branch        | Environment | Notes                                               |
| ------------- | ----------- | --------------------------------------------------- |
| `main`        | prod        | Protected. Merges via PR only.                      |
| `stage`       | stage       | Direct push allowed.                                |
| `development` | development | Direct push allowed. Quiesced by default.           |

Pushes from any other branch (feature branches, tags) do not auto-deploy. CI/CD workflows only fire on the three named branches.

The `development` environment is a warm spare. It runs only when:

- A change is too risky for stage (destructive infra changes, security-sensitive surface), or
- Infra changes need to be applied to be validated.

Otherwise leave it quiesced. Most work goes `stage` -> `main` with one deliberate promotion step. See [docs/quiesce.md](docs/quiesce.md).

### Direct-to-prod scaffolding

Some features are too expensive to run in multiple environments and ship via a feature branch -> `main` PR, skipping stage. This is allowed only when **all** of the following are true:

- No data plane impact (no schema changes, no message-flow changes, no DynamoDB writes).
- No user-facing surface (no UI, API contract, or auth-flow changes).
- No IAM or security implications (no new principals, no new permissions, no public surface).
- The change is purely additive: new resources that no existing path references.

If any of these is unclear, route through stage first.

### Claude automation

The `claude` issue label triggers an automated PR. PRs target `stage`, never `main`. Promotion to `main` is always a deliberate second step the human performs.

## Repository Structure

```
react/admin/        React frontend (email client + address/folder management)
apple/              Native Apple clients (iOS + macOS, SwiftUI) and CabalmailKit
lambda/api/         AWS Lambda functions behind API Gateway (Python)
lambda/counter/     Cognito post-confirmation trigger (Python)
lambda/certbot-renewal/  Let's Encrypt certificate renewal Lambda
terraform/dns/      Bootstrap stack: Route 53 zone for the control domain
terraform/infra/    Main stack: VPC, ECS, ELB, Cognito, DynamoDB, CloudFront, Lambda, etc.
docker/             Container images for mail tiers (imap, smtp-in, smtp-out)
docs/               Architecture docs, migration plans, setup guides
.github/workflows/  CI/CD pipelines for all components
.github/scripts/    Shared build/deploy helper scripts
```

### Docs convention

Versioned subdirectories of `docs/` (e.g. `docs/0.4.0/`, `docs/0.7.0/`, `docs/0.9.x/`) are forward-looking plans for the corresponding roadmap version - design proposals written before or during implementation. Once a feature ships, its as-implemented documentation lives at the top level of `docs/`, not inside the version directory. When you write operator-facing or reference documentation for something that has already shipped, put it in `docs/<topic>.md` and link it from the relevant index (`docs/operations.md`, `docs/setup.md`, etc.). Leave the version directory alone; it is part of the historical planning record.

## Build/Lint/Test Commands

### React App (`react/admin`)
- Dev server: `cd react/admin && npm run start` (Vite, port 3000)
- Build: `cd react/admin && npm run build` (outputs to `dist/`)
- Tests: `cd react/admin && npm run test` (Vitest + jsdom)
- Single test: `cd react/admin && npm run test -- -t "test name"`
- Watch mode: `cd react/admin && npm run test:watch`

### Lambda Functions (`lambda/api`)
- Lint all: `cd lambda/api && pylint --rcfile .pylintrc _shared/*.py */function.py` (covers the shared modules and every handler)
- Local test: `cd lambda/api/[function_dir] && python -m function`

### Apple Clients (`apple/`)
- Generate Xcode project: `cd apple && xcodegen generate` (regenerates `Cabalmail.xcodeproj` from `project.yml`; not committed)
- Kit tests: `cd apple/CabalmailKit && swift test` (only automated coverage for the Apple side)
- iOS build sanity check: `cd apple && xcodebuild -workspace Cabalmail.xcworkspace -scheme Cabalmail -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
- CI: `apple.yml` builds and tests on a macOS runner; does not deploy anything to AWS

### Terraform
- Terraform is applied via CI/CD only (`.github/workflows/infra.yml`)
- Two stacks: `terraform/dns` (bootstrap) and `terraform/infra` (main), both owned by `infra.yml`
- Backend: S3 (`cabal-tf-backend` bucket), key pattern `{environment}-{module}`
- Environment determined by branch: `main`=prod, `stage`=stage, `development`=development. Other branches do not trigger deploys.
- Backend config is generated at CI time by `.github/scripts/make-terraform.sh`
- Security scanning: Checkov, tflint, tfsec all run in the terraform workflow

### Docker Images
- Built and pushed via `.github/workflows/app.yml` (the `docker` job)
- Three core tiers built in matrix: `imap`, `smtp-in`, `smtp-out`. When `vars.TF_VAR_MONITORING == 'true'` the matrix also builds `uptime-kuma`, `ntfy`, `healthchecks`, `prometheus`, `alertmanager`, `grafana`, `cloudwatch-exporter`, `blackbox-exporter`, `node-exporter`
- Images tagged `sha-{first8}` and pushed to ECR (`cabal-{tier}`)
- A certbot-renewal image is also built (arm64, for Lambda container) by the `lambda-certbot` job in `app.yml`
- Each `docker` matrix job deploys directly to ECS via `aws ecs register-task-definition` + `aws ecs update-service` (see `.github/scripts/deploy-ecs-service.sh`); no Terraform on the deploy path

## CI/CD Workflows (`.github/workflows/`)

| Workflow | Trigger (path) | What it does |
|---|---|---|
| `app.yml` | `docker/**`, `lambda/**`, `react/admin/**` | Per-area path-filtered parallel build + out-of-band deploy: ECS update-service for docker tiers and certbot, `aws lambda update-function-code` for api/counter zips, `s3 sync` + CloudFront invalidation for the React bundle. Does not touch Terraform. |
| `infra.yml` | `terraform/dns/**`, `terraform/infra/**` | Owns both the bootstrap (`terraform/dns`) and main (`terraform/infra`) stages. Bootstrap is gated on a `dorny/paths-filter` step or a `workflow_dispatch` boolean. Runs Checkov/tflint/tfsec, plans, applies, then `post-apply-update-services.sh` to roll any ECS services whose task-def family advanced. |
| `quiesce.yml` | Manual (`workflow_dispatch`) | Scales a non-prod env's ECS services, ECS-instance ASG, and NAT instances to zero (or restores them). Refuses to run against prod. See `docs/quiesce.md`. |
| `destroy_terraform.yml` | Manual (`workflow_dispatch`) | Tears down `terraform/infra` for the selected environment. |
| `apple.yml` | `apple/**` | Builds and tests the iOS app on a macOS runner. Deploys nothing to AWS. |
| `dependabot.yml` | Schedule (daily) | Dependency update PRs. |
| `claude.yml` | `@claude` mention | Claude Code action for PR review. |
Deploy workflows select environment based on branch: `main`=prod, `stage`=stage, `development`=development. Other branches do not trigger deploys (see "Branches and environments" above).

## Architecture Details

### Domain Model

- **Users, mailboxes, addresses.** 1 Cognito user <-> 1 mailbox, provisioned automatically by the post-confirmation Lambda (`lambda/counter`) when the user is confirmed. 1 mailbox <-> n addresses, managed by the user via the admin app's `new`/`revoke` API endpoints (rows in the `cabal-addresses` DynamoDB table). Addresses are a *user feature* — spinning them up per-vendor or per-purpose and revoking them when burned — not infrastructure.
- **No apex addressing.** Mail domains in `TF_VAR_MAIL_DOMAINS` (e.g. `cabalmail.com`) host email *only* on subdomains. The apex itself has no MX, no A, no addressing — it's deliberate, not a missing feature. The IMAP tier's sendmail `check_mail` rule does an MX-then-A DNS lookup on the envelope sender and 553-rejects FROM addresses on the apex. Don't compose system-level FROM, NOTIFICATIONS_EMAIL, or service-account addresses on the apex; use **`mail-admin.<first-mail-domain>`** (provisioned by `terraform/infra/modules/app/dmarc_user.tf` with full MX/SPF/DKIM/DMARC) for system-originated mail. The local part is free to vary (`noreply@`, `healthchecks@`, etc.).

### Terraform Modules (`terraform/infra/modules/`)

| Module | Purpose |
|---|---|
| `vpc` | VPC, subnets (public/private), NAT instance, Route 53 private zone |
| `ecs` | ECS cluster, task definitions, services, target groups, SNS/SQS for reconfiguration |
| `elb` | Network Load Balancer: IMAP (993), SMTP relay (25), submission (587/465) |
| `app` | CloudFront distribution, API Gateway, Lambda functions, SSM parameters |
| `s3` | S3 bucket for React app + Lambda artifacts |
| `ecr` | ECR repositories for container images |
| `efs` | EFS filesystem for mailstore |
| `user_pool` | Cognito User Pool + post-confirmation trigger |
| `table` | DynamoDB `cabal-addresses` table |
| `cert` | ACM certificate for control domain |
| `domains` | Route 53 hosted zones for mail domains |
| `certbot_renewal` | Scheduled Lambda for Let's Encrypt cert renewal |
| `backup` | AWS Backup for DynamoDB + EFS (conditional) |

Image tags are stored in SSM Parameter Store (`/cabal/deployed_image_tag`) and read by Terraform at plan time.

### Lambda Functions (`lambda/api/`)

All Lambda functions are Python, fronted by API Gateway with Cognito authorizer. They share a first-party helper module at [`lambda/api/_shared/helper.py`](lambda/api/_shared/helper.py), copied into each consuming function's zip at build time (see [`build-api-one.sh`](.github/scripts/build-api-one.sh)), providing:
- IMAP client management (master-user login via SSM-stored password, username format `{user}*admin`)
- DynamoDB address lookups (`cabal-addresses` table)
- S3 message caching (raw email bodies cached at `{user}/{folder}/{id}/raw`)
- Presigned URL generation for attachments (24hr expiry)

Key dependencies: `imapclient==2.3.1`, `dnspython==2.3.0` (bundled per function via `requirements.txt`; previously shipped as a Lambda layer, removed in 0.9.x). IMAP folder paths use `.` internally but `/` in API requests — all functions normalize with `.replace("/", ".")`.

Response format: `{"statusCode": N, "body": json.dumps({...})}`. User extracted from `event['requestContext']['authorizer']['claims']['cognito:username']`.

| Function | Purpose |
|---|---|
| `list` | List user's email addresses |
| `new` | Create a new email address |
| `revoke` | Delete an email address |
| `list_folders` | List IMAP folders |
| `new_folder` / `delete_folder` | Create/delete IMAP folders |
| `subscribe_folder` / `unsubscribe_folder` | Manage folder subscriptions |
| `list_messages` / `list_envelopes` | List messages / fetch envelope data |
| `fetch_message` | Fetch full email body (with S3 cache) |
| `fetch_attachment` / `list_attachments` / `fetch_inline_image` | Attachment handling |
| `fetch_bimi` | BIMI logo lookup for sender domains |
| `send` | Send email via SMTP |
| `move_messages` / `set_flag` | IMAP message operations |
| `purge_messages` / `empty_trash` | Permanently delete (expunge) messages; trash folders only |

### React App (`react/admin/`)

- **React 17** with class-based components, Vite build tooling, Vitest for tests
- **Auth**: Amazon Cognito (`amazon-cognito-identity-js`) — signup, login, JWT token management
- **API**: Axios-based `ApiClient` class, all calls include Cognito JWT in Authorization header
- **State**: Component-level state with `localStorage` persistence (no Redux/Context for app state)
- **Contexts**: `AuthContext` (token/api_url/host/domains), `AppMessageContext` (toast notifications)
- **Email**: Rich text compose with Draft.js/react-draft-wysiwyg, DOMPurify for HTML sanitization
- **Key views**: Email (inbox/folders/compose), Addresses (list/request/revoke), Folders (manage), Login/SignUp
- **Config**: Fetched at runtime from `/config.js` (served by CloudFront, generated by Terraform)

### Apple Clients (`apple/`)

Native SwiftUI clients for iOS (iPhone/iPad), macOS, and visionOS. The Xcode project is generated by `xcodegen` from `apple/project.yml` (run `xcodegen generate` in `apple/`); the `.xcodeproj` is not committed.

- **`Cabalmail/`** — iOS/visionOS app target (views, view models, app shell)
- **`CabalmailMac/`** — native macOS app target (not Catalyst)
- **`CabalmailKit/`** — Swift package shared by both targets; holds all networking, parsing, caching, auth, and IMAP/SMTP code. The test suite (`swift test` from `apple/CabalmailKit/`) is the only automated coverage for the Apple clients.

**Mail traffic goes through the Lambda API, not direct IMAP.** `CabalmailKit/CabalmailClient.live(...)` wires the production `imapClient` to `ApiBackedImapClient`, which adapts the React-shaped Lambda endpoints (`/list_folders`, `/list_envelopes`, `/fetch_message`, `/set_flag`, `/move_messages`, `/send`, etc.) onto the `ImapClient` protocol. Issue #371 captures the switch: the hand-rolled IMAP stack (`LiveImapClient`, `ImapConnection`, `NetworkByteStream`) proved unreliable across network transitions, sleep/wake, and provider quirks, while the React client had been running off the same Lambda surface since 0.2.0 with no such trouble. **Before debugging anything that looks like an IMAP-level issue in the Apple clients, confirm which `ImapClient` is wired up — `LiveImapClient` still compiles and has its own tests, but production paths don't use it.** Errors that say "cancelled" in the UI typically come from `URLError.cancelled` (URLSession data task), not the `CabalmailError.cancelled` enum case.

Trade-offs of the API-backed path (full notes in `apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift`): no IDLE (folder status is polled), no APPEND (`/send` handles Outbox + Sent server-side), no `fetchPart` (fetch the full body and parse MIME client-side), and envelope display names are flattened to bare addresses.

### Docker Services (`docker/`)

Three container images based on `amazonlinux:2023`, managed by supervisord:
- **`imap`**: Dovecot (IMAP) + Sendmail (local delivery) + Procmail
- **`smtp-in`**: Sendmail (inbound relay)
- **`smtp-out`**: Sendmail (outbound) + Dovecot (submission auth) + OpenDKIM

Shared infrastructure:
- `docker/shared/entrypoint.sh` — writes TLS certs, renders sendmail.mc, generates Cognito auth script, syncs OS users, generates sendmail maps from DynamoDB
- `docker/shared/generate-config.sh` — scans DynamoDB, generates virtusertable, access maps, relay-domains, DKIM tables
- `docker/shared/reconfigure.sh` — live reconfiguration triggered by SNS/SQS when addresses change
- `docker/shared/sync-users.sh` — creates OS users from Cognito user pool
- `docker/templates/` — sendmail `.mc` templates with `__CERT_DOMAIN__` placeholders

## Code Style Guidelines

- **JavaScript/React**:
  - Class-based React components with explicit state management (soon to migrate to function-based components)
  - Import order: third-party libs, main components, utilities, styles
  - Error handling with try/catch blocks and explicit error messaging
  - Use camelCase for variables/functions, PascalCase for components
  - JSDoc comments for function documentation

- **Python**:
  - Function docstrings using triple quotes
  - Snake_case for variables and functions
  - Disable specific pylint warnings with inline comments when necessary
  - Import standard libs first, then custom modules

- **Terraform**:
  - Follow HashiCorp style conventions
  - Document modules and variables thoroughly
  - Group related resources in modules
  - Use locals for repeated values or complex expressions

- **Docker/Shell**:
  - `set -euo pipefail` in all scripts
  - Structured logging with `[component]` prefixes
  - Environment variable validation at script entry
  - Comments explaining non-obvious configuration choices

## CHANGELOG

Use semantic versioning. Record changelog entries as **fragments**, not by editing `CHANGELOG.md` directly: add a file `changelog.d/<slug>.<category>.md` whose body is the entry exactly as it should appear (leading `- `, hard-wrapped, two-space continuation indent). `<category>` is one of `added`/`changed`/`deprecated`/`removed`/`fixed`/`security`. Do not create an `## [Unreleased]` section and do not pre-assign a version - the release collator (`.github/scripts/collate-changelog.sh`, run by `promote.sh` / `make promote`) folds every pending fragment into a dated section at release time. Only record what shipped, not trials or blind alleys. See [`changelog.d/README.md`](changelog.d/README.md) and [`docs/releasing.md`](docs/releasing.md).

## Roadmap

See the [project wiki](https://github.com/cabalmail/cabal-infra/wiki) for the current roadmap.

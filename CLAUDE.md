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
| `main`        | prod        | Protected. Receives only `stage` promotion PRs.     |
| `stage`       | stage       | Direct push allowed.                                |
| `development` | development | Direct push allowed. Quiesced by default.           |

Pushes from any other branch (feature branches, tags) do not auto-deploy. CI/CD workflows only fire on the three named branches.

The `development` environment is a warm spare. It runs only when:

- A change is too risky for stage (destructive infra changes, security-sensitive surface), or
- Infra changes need to be applied to be validated.

Otherwise leave it quiesced. All work goes `stage` -> `main` with one deliberate promotion step. See [docs/quiesce.md](docs/quiesce.md).

### Promotion to prod

The only route to `main` is promoting `stage`. The promotion is a formal release step: from a clean `stage` tree, `make promote VERSION=...` collates the pending changelog fragments, commits and pushes `stage`, and opens the `stage` -> `main` PR; merging that PR is a deliberate manual act, and `release.yml` tags and publishes the GitHub release on merge. See [docs/releasing.md](docs/releasing.md).

Never open a PR to `main` from any other branch. An earlier "direct-to-prod scaffolding" carve-out allowed purely additive feature-branch -> `main` PRs to skip stage; it was retired 2026-08-15 — the automated release flow made promotion cheap enough that skipping stage no longer pays for the risk. Shipped-era planning docs that relied on it carry errata.

### No PII in public artifacts

This repository is public. Never put PII — real names, production email addresses, phone numbers, or anything else identifying a real person — in code comments, commit messages, issue titles/descriptions, PR titles/descriptions/comments, changelog fragments, docs, test fixtures, or anywhere else that is or might be publicly exposed. When a live example is required, use a stage-environment address instead of a production one.

## Repository Structure

```
react/admin/        React frontend (email client + address/folder management)
apple/              Native Apple clients (iOS + macOS, SwiftUI) and CabalmailKit
linux/              Native Linux client (GTK4 + libadwaita, Rust) — in progress, see docs/1.1.x/linux-client-plan.md
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

Versioned subdirectories of `docs/` (e.g. `docs/0.4.0/`, `docs/0.7.0/`, `docs/0.9.x/`) are forward-looking plans for the corresponding roadmap version - design proposals written before or during implementation. Once a feature ships, its as-implemented documentation lives at the top level of `docs/`, not inside the version directory. When you write operator-facing or reference documentation for something that has already shipped, put it in `docs/<topic>.md` and link it from the relevant index (`docs/operations.md`, `docs/setup.md`, etc.). Leave the version directory alone; it is part of the historical planning record. One exception: when a plan's claim is later proven wrong, add a dated erratum blockquote (`> **Erratum (YYYY-MM-DD):** ...`) immediately after the paragraph or bullet containing the falsified claim - at the top of the file if the whole doc is invalidated, never as a trailing section (windowed reads miss it). Never rewrite or delete the original text. When an erratum contradicts its surrounding text, the erratum is the corrected record - trust it.

## Build/Lint/Test Commands

### React App (`react/admin`)
- Dev server: `cd react/admin && npm run start` (Vite, port 3000)
- Build: `cd react/admin && npm run build` (outputs to `dist/`)
- Tests: `cd react/admin && npm run test` (Vitest + jsdom)
- Single test: `cd react/admin && npm run test -- -t "test name"`
- Watch mode: `cd react/admin && npm run test:watch`

### Lambda Functions (`lambda/api`)
- Lint all: `cd lambda/api && pylint --rcfile .pylintrc _shared/*.py */function.py push_dispatch/apns.py` (covers the shared modules, every handler, and the one handler-sibling module the `*/function.py` glob misses)
- Local test: `cd lambda/api/[function_dir] && python -m function`

### Apple Clients (`apple/`)
- Generate Xcode project: `cd apple && xcodegen generate` (regenerates `Cabalmail.xcodeproj` from `project.yml`; not committed. Also materializes the gitignored marked/turndown web assets via `scripts/sync-vendored.sh` — needs node/npm the first time. Building from a checkout without those assets produces an app whose rich-text bridge never boots; run `swift test` setups through the same script.)
- Kit tests: `cd apple/CabalmailKit && swift test` (the bulk of the Apple-side coverage — networking, parsing, caching, auth)
- App-layer tests: `cd apple && xcodebuild test -workspace Cabalmail.xcworkspace -scheme CabalmailMac -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` — XCTest suite for the app target's view models (`apple/CabalmailTests/`, e.g. bulk-selection/move flows against a `FakeImapClient`). `swift test` does **not** compile or run these, and `apple.yml` runs them only on push to a named branch, not on PRs — so run them locally before merging a change to a shared protocol (e.g. `ImapClient`) or a view model.
- iOS build sanity check: `cd apple && xcodebuild -workspace Cabalmail.xcworkspace -scheme Cabalmail -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
- CI: `apple.yml` builds and tests on a macOS runner; does not deploy anything to AWS

### Linux Client (`linux/`)
- Toolchain: **rustup**, not the distro `rust` package — only rustup honours the exact pin in `linux/rust-toolchain.toml` (1.97.1), and on Arch the two packages conflict
- Build: `cd linux && cargo build --workspace`
- Kit tests: `cd linux && cargo test -p cabalmail-kit` (no display server, no network — keep it that way; `cabalmail-kit` must never gain a GTK/libadwaita/WebKit dependency)
- Repo-shape and drift tests: `cd linux && cargo test -p xtask` — the checks that reach outside the workspace. One asserts the client's synced-preference keys and enum values match `APP_ALLOWED` in [`lambda/api/set_preferences/function.py`](lambda/api/set_preferences/function.py); the server rejects an unknown key in the `app` map with a 400 *by design*, so a divergence would surface as a failed push at runtime. Another asserts the generated docs are current — after changing `linux/cabalmail-kit/src/config/schema.rs`, regenerate `cabalmail-gtk/data/config.example.toml` and the `cabalmail.5.md` key list with `CABALMAIL_UPDATE_DOCS=1 cargo test -p xtask`
- App tests: `cd linux && cargo test -p cabalmail-gtk` — the async-bridge and data-file tests need no display; the widget tests do, and skip with a message when there is none (CI runs them under `xvfb-run`)
- Everything CI runs, in CI's order: `cd linux && cargo xtask ci` — fmt, clippy, kit tests, xtask tests, app tests, stopping at the first failure. Run it before every push; `linux.yml` runs the same steps by name (`cargo xtask ci --step <name>`, one per job) rather than restating the commands in YAML, and `xtask/tests/workflow_contract.rs` fails if a step has no job or a job names a step that does not exist. `cargo xtask sync-vendored` materializes the composer's marked/turndown bundles (gitignored) from `react/admin/node_modules`, mirroring the Apple flow. `package`, `smoke`, and `fixtures` are declared but land in Phase 2; asking for one prints the work item that owns it
- Building `cabalmail-gtk` needs `blueprint-compiler` and `glib-compile-resources` on `PATH`: `build.rs` compiles `cabalmail-gtk/resources/*.blp` to GtkBuilder XML and bundles it as a GResource. A missing compiler is a hard build failure naming the package — there is deliberately no `.ui` fallback, since two UI formats in one tree is worse than a build that stops
- The API floor is GTK 4.14 / libadwaita 1.4 (Ubuntu 24.04 LTS), enforced by the `v4_14` / `v1_4` features on the `gtk4` / `libadwaita` crates. Newer API does not compile even on Arch's GTK 4.22 — that is intentional; don't raise the features to make a call site build
- Every `cabalmail-kit` call from the UI goes through `spawn_to_ui!` (`cabalmail-gtk/src/runtime.rs`): one tokio runtime owned by the application, results delivered to a `glib::spawn_future_local` task, widgets captured weakly via `glib::clone!`. Never block the GTK main thread on a future, and never capture a widget across the boundary
- The app crate builds the `cabalmail` binary
- CI: `linux.yml` runs one `cargo xtask ci` step per job. `clippy` and the widget tests run inside an `ubuntu:24.04` container — that is where the API floor is enforced, so a call needing GTK 4.16 fails `app-build` and leaves the format job green. System packages come from `linux/packaging/deps/<distro>.txt` via `.github/scripts/install-linux-deps.sh`, the same list the Debian packaging reads in Phase 8. Packaging, smoke, coverage, and the cargo-deny/tree guards are still to come; the workflow names the work item that owns each

### Android Client (`android/`)
- Toolchain: JDK 17+ on `JAVA_HOME` (CI uses Temurin 21) and an Android SDK (`local.properties` or `ANDROID_HOME`); Gradle fetches missing SDK components itself
- Build: `cd android && ./gradlew assembleDebug`
- Kit tests: `cd android && ./gradlew :kit:test` (JUnit 5; the `kit` module is the UI-free sibling of `CabalmailKit` — keep it free of Compose/UI dependencies)
- App tests: `cd android && ./gradlew :app:testDebugUnitTest`
- Lint: `cd android && ./gradlew ktlintCheck lint` (`ktlintFormat` auto-fixes). Android Lint warnings are **errors** in both modules; version-freshness checks are disabled because dependabot owns the version catalog
- The control domain is the only build-time value (`BuildConfig.CONTROL_DOMAIN`); point local builds at a live environment via `cabalmail.controlDomain` in `~/.gradle/gradle.properties` — never commit a real domain, the checked-in default is a placeholder
- CI: `lint.yml`'s `kotlin` job runs the same gradle gate on PRs; `android.yml` runs it again on `stage`/`main` pushes and deploys nothing to AWS (its only side effect is a Play Console upload)

### Terraform
- Terraform is applied via CI/CD only (`.github/workflows/infra.yml`)
- Two stacks: `terraform/dns` (bootstrap) and `terraform/infra` (main), both owned by `infra.yml`
- Backend: S3 (`cabal-tf-backend` bucket), key pattern `{environment}-{module}`
- Environment determined by branch: `main`=prod, `stage`=stage, `development`=development. Other branches do not trigger deploys.
- Backend config is generated at CI time by `.github/scripts/make-terraform.sh`
- Security scanning: Checkov, tflint, tfsec all run in the terraform workflow

### Docker Images
- Built and pushed via `.github/workflows/app.yml` (the `docker` job)
- Three core tiers in the matrix: `imap`, `smtp-in`, `smtp-out`. When `vars.TF_VAR_MONITORING == 'true'` the matrix also includes `uptime-kuma`, `ntfy`, `healthchecks`, `prometheus`, `alertmanager`, `grafana`, `cloudwatch-exporter`, `blackbox-exporter`, `node-exporter`
- Pushes build only the tiers whose inputs changed (per-tier `docker_*` filters in `app.yml`; core tiers also rebuild on `docker/shared/**` and their own `docker/templates/*.mc`). `check-docker-tier-filters.sh` fails CI if a Dockerfile `COPY` drifts from the filter map. A `workflow_dispatch` run builds every tier in scope; `force_tiers` narrows it.
- Images tagged `sha-{first8}` and pushed to ECR (`cabal-{tier}`)
- A certbot-renewal image is also built (arm64, for Lambda container) by the `lambda-certbot` job in `app.yml`
- Each `docker` matrix job deploys directly to ECS via `aws ecs register-task-definition` + `aws ecs update-service` (see `.github/scripts/deploy-ecs-service.sh`); no Terraform on the deploy path

## CI/CD Workflows (`.github/workflows/`)

| Workflow | Trigger (path) | What it does |
|---|---|---|
| `app.yml` | `docker/**`, `lambda/**`, `react/admin/**` | Per-area (and, within docker, per-tier) path-filtered parallel build + out-of-band deploy: ECS update-service for the changed docker tiers and certbot, `aws lambda update-function-code` for api/counter zips, `s3 sync` + CloudFront invalidation for the React bundle. Does not touch Terraform. |
| `infra.yml` | `terraform/dns/**`, `terraform/infra/**` | Owns both the bootstrap (`terraform/dns`) and main (`terraform/infra`) stages. Bootstrap is gated on a `dorny/paths-filter` step or a `workflow_dispatch` boolean. Runs Checkov/tflint/tfsec, plans, applies, then `post-apply-update-services.sh` to roll any ECS services whose task-def family advanced. |
| `quiesce.yml` | Manual (`workflow_dispatch`) | Scales a non-prod env's ECS services, ECS-instance ASG, and NAT instances to zero (or restores them). Refuses to run against prod. See `docs/quiesce.md`. |
| `destroy_terraform.yml` | Manual (`workflow_dispatch`) | Tears down `terraform/infra` for the selected environment. |
| `apple.yml` | `apple/**` | Builds and tests the iOS app on a macOS runner. Deploys nothing to AWS. |
| `linux.yml` | `linux/**` | Runs the Linux client's gate, one `cargo xtask ci` step per job; the workspace build and widget tests run in an `ubuntu:24.04` container (the GTK 4.14 API floor). Deploys nothing to AWS. |
| `android.yml` | `android/**` | On `main`/`stage` pushes: tests (unit + ktlint + Android Lint with warnings-as-errors), an unsigned release build, then a signed AAB upload to the Play Console internal track via gradle-play-publisher (warn-green while the Play/signing secrets are absent). PR-time linting lives in `lint.yml`'s `kotlin` job, which runs the same gradle gate. Deploys nothing to AWS. |
| `dependabot.yml` | Schedule (daily) | Dependency update PRs. |
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

Image tags are stored per tier in SSM Parameter Store (`/cabal/deployed_image_tag/<tier>`, reconciled with the running services by `refresh-ssm-from-running.sh` before each plan) and read by Terraform at plan time; the legacy `/cabal/deployed_image_tag` key tracks the imap tier and is the fallback/bootstrap sentinel.

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
| `send` | Send email via SMTP (optionally discarding a superseded draft copy) |
| `save_draft` | Save/replace/discard a draft in the Drafts folder (UIDPLUS lifecycle) |
| `move_messages` / `set_flag` | IMAP message operations |
| `purge_messages` / `empty_trash` | Permanently delete (expunge) messages; trash folders only |

### React App (`react/admin/`)

- **React 18** with function components and hooks (only `ErrorBoundary` remains class-based), Vite build tooling, Vitest for tests
- **Auth**: Amazon Cognito (`amazon-cognito-identity-js`) — signup, login, JWT token management
- **API**: Axios-based `ApiClient` class, all calls include Cognito JWT in Authorization header
- **State**: Component-level state with `localStorage` persistence (no Redux for app state). Auth tokens are the deliberate exception: they live in a module-level variable in `App.jsx` and must never be written to `localStorage`
- **Contexts**: `AuthContext` (token/api_url/host/domains), `AppMessageContext` (toast notifications)
- **Email**: Rich text compose with TipTap (`@tiptap/react`). Received HTML is rendered in a sandboxed iframe with no `allow-scripts` (see `Email/ReaderBody.jsx`), which is what neutralizes scripts — there is no library HTML sanitizer. Do not add `allow-scripts` to that sandbox
- **Key views**: Email (inbox/folders/compose), Addresses (list/request/revoke), Folders (manage), Login/SignUp
- **Config**: Fetched at runtime from `/config.js` (served by CloudFront, generated by Terraform)

### Apple Clients (`apple/`)

Native SwiftUI clients for iOS (iPhone/iPad), macOS, and visionOS. The Xcode project is generated by `xcodegen` from `apple/project.yml` (run `xcodegen generate` in `apple/`); the `.xcodeproj` is not committed.

- **`Cabalmail/`** — iOS/visionOS app target (views, view models, app shell)
- **`CabalmailMac/`** — native macOS app target (not Catalyst)
- **`CabalmailKit/`** — Swift package shared by both targets; holds all networking, parsing, caching, auth, and IMAP/SMTP code. Its `swift test` suite (from `apple/CabalmailKit/`) carries the bulk of the Apple-side coverage. The app targets add a smaller XCTest suite in `apple/CabalmailTests/` (run via the `CabalmailMac` scheme — see Build/Lint/Test Commands) for view-model logic; that one is **not** part of `swift test` and CI runs it only on push to a named branch.

**Mail traffic goes through the Lambda API, not direct IMAP.** `CabalmailKit/CabalmailClient.live(...)` wires the production `imapClient` to `ApiBackedImapClient`, which adapts the React-shaped Lambda endpoints (`/list_folders`, `/list_envelopes`, `/fetch_message`, `/set_flag`, `/move_messages`, `/send`, etc.) onto the `ImapClient` protocol. Issue #371 captures the switch: the hand-rolled IMAP stack (`LiveImapClient`, `ImapConnection`, `NetworkByteStream`) proved unreliable across network transitions, sleep/wake, and provider quirks, while the React client had been running off the same Lambda surface since 0.2.0 with no such trouble. **Before debugging anything that looks like an IMAP-level issue in the Apple clients, confirm which `ImapClient` is wired up — `LiveImapClient` still compiles and has its own tests, but production paths don't use it.** Errors that say "cancelled" in the UI typically come from `URLError.cancelled` (URLSession data task), not the `CabalmailError.cancelled` enum case.

Trade-offs of the API-backed path (full notes in `apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift`): no IDLE (folder status is polled), no raw APPEND (`/send` handles Outbox + Sent server-side; `/save_draft` owns the Drafts lifecycle, which the Apple draft sync uses — see `docs/draft-sync-and-threading.md`), and no `fetchPart` (fetch the full body and parse MIME client-side). Envelopes carry RFC 5322 display-name mailbox strings and, since 0.10.x, the threading identity (`message_id` / `in_reply_to` / `references`).

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
  - Function components with hooks
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
  - `set -euo pipefail` in all scripts (a best-effort delivery-path side
    effect may drop `-e` with an in-file comment justifying it and explicit
    handling on every failure path; see docker/shared/push-enqueue.sh)
  - Structured logging with `[component]` prefixes
  - Environment variable validation at script entry
  - Comments explaining non-obvious configuration choices

## CHANGELOG

Use semantic versioning. Record changelog entries as **fragments**, not by editing `CHANGELOG.md` directly: add a file `changelog.d/<slug>.<category>.md` whose body is the entry exactly as it should appear (leading `- `, hard-wrapped, two-space continuation indent). `<category>` is one of `added`/`changed`/`deprecated`/`removed`/`fixed`/`security`. Do not create an `## [Unreleased]` section and do not pre-assign a version - the release collator (`scripts/collate-changelog.sh`, run by `promote.sh` / `make promote`) folds every pending fragment into a dated section at release time. Only record what shipped, not trials or blind alleys. See [`changelog.d/README.md`](changelog.d/README.md) and [`docs/releasing.md`](docs/releasing.md).

Don't repeat the category subheading word (or a close synonym) in the fragment text - the collator already prints it as an `### Added:`/`### Removed:`/etc. heading, so "Added a new UI element for X" reads as redundant under `### Added:`. Instead, lead with a bold noun-phrase summary followed by details: `- **New UI element for X.** <details>`. Same for `Removed`, `Deprecated`, `Changed`, `Fixed`, `Security`.

Any fragment describing a change to the **Apple clients** (`apple/Cabalmail`, `apple/CabalmailMac`, `apple/CabalmailKit/Sources`) **must** prefix its entry with `Apple:` - right after the leading `- ` and before the bold summary: `- Apple: **Threaded reader.** <details>`. This prefix scopes the entry into the TestFlight "What to Test" notes: `set-testflight-notes.py` keeps only `Apple:`-prefixed entries (stripping the prefix, since it's redundant in an Apple app) and drops the rest, so an Apple change without the prefix silently vanishes from the notes testers read. A PR that touches the Apple client sources fails the `apple-changelog.yml` gate unless it adds such a fragment; opt out for non-user-facing Apple work (refactors, test-only, CI) with the `no-changelog` PR label.

## Roadmap

See the [project wiki](https://github.com/cabalmail/cabal-infra/wiki) for the current roadmap.

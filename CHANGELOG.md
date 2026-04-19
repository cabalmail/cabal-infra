# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - Unreleased

### Added

- `apple/` — Phase 1 scaffolding for the native Apple client (iOS/iPadOS/visionOS app target + native macOS app target + shared `CabalmailKit` Swift package with `Configuration` model and smoke tests)
- `apple/project.yml` — XcodeGen spec; the `.xcodeproj` is generated at build time rather than committed
- `apple/Local.xcconfig.example` — template for a gitignored per-developer xcconfig supplying `DEVELOPMENT_TEAM`
- `.github/workflows/apple.yml` — Phase 2 CI/CD for the Apple client: `kit-test` (SwiftLint + CabalmailKit tests across macOS/iOS/visionOS), `app-build` (unsigned build of both app targets), `upload-ios` (archive + TestFlight upload, main/stage only), `upload-mac` (archive + TestFlight upload + developer-id notarization + workflow artifact, main/stage only)
- `apple/.swiftlint.yml` — permissive SwiftLint configuration tuned for the current scaffold
- `apple/ci/ExportOptions-iOS.plist`, `apple/ci/ExportOptions-macOS.plist`, `apple/ci/ExportOptions-macOS-DeveloperID.plist` — archive export configurations used by the upload jobs
- `apple/scripts/generate-placeholder-icons.sh` + `generate-placeholder-icon.swift` — one-shot generator for a 1024×1024 placeholder app icon (rendered via CGContext for exact pixel dimensions) and sips-derived macOS icon catalog sizes. Replace output with real artwork before non-internal distribution
- `CFBundleIconName: AppIcon` and `ITSAppUsesNonExemptEncryption: false` set on both app targets via `project.yml` — required by App Store validation for icon-catalog apps and pre-answers the TestFlight export-compliance prompt for HTTPS-only traffic
- Terraform: `aws_s3_object.website_config_json` in `terraform/infra/modules/app/s3.tf` — publishes `/config.json` alongside `/config.js` so the Apple client has a parseable runtime configuration source
- Documentation: Phase 1 decisions recorded in `apple/README.md` (native macOS target over Mac Catalyst; `config.json` delivery over bundled `.xcconfig`); Phase 2 CI layout and required GitHub secrets documented in the same file
- **Apple client Phase 3 — Authentication & Transport** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.AuthService` protocol + `CognitoAuthService` actor — hand-rolled Cognito `USER_PASSWORD_AUTH` / `REFRESH_TOKEN_AUTH` over `URLSession`, plus sign-up, confirm, forgot-password, resend flows. Matches the pool's `explicit_auth_flows = ["USER_PASSWORD_AUTH"]` so no AWS Amplify dependency is required.
  - `CabalmailKit.SecureStore` protocol with a Security-framework-backed `KeychainSecureStore` (data-protection keychain, shared iOS/macOS) and an `InMemorySecureStore` for tests. Tokens persist as a single JSON blob; IMAP username/password live in separate keychain items so sign-out clears them alongside the tokens.
  - `CabalmailKit.ApiClient` protocol + `URLSessionApiClient` actor — attaches the Cognito ID token to every request, transparently retries once on 401 after forcing a refresh, and surfaces a second 401 as `.authExpired`. Backs `/list`, `/new`, `/revoke`, and `/fetch_bimi`.
  - `CabalmailKit.ImapClient` protocol + `LiveImapClient` actor — TLS-from-connect IMAPS (993) via a `NetworkByteStream` built on `NWConnection`. Supports LOGIN, LIST/LSUB with `/`↔`.` delimiter translation, CREATE/DELETE/SUBSCRIBE/UNSUBSCRIBE, STATUS, SELECT, UID FETCH (ENVELOPE/FLAGS/BODYSTRUCTURE/RFC822.SIZE/INTERNALDATE/BODY[]), UID STORE, UID MOVE (with COPY+STORE+EXPUNGE fallback for servers without RFC 6851), UID SEARCH, APPEND, LOGOUT, and IDLE (via a dedicated second connection yielding an `AsyncThrowingStream<IdleEvent, Error>`).
  - `CabalmailKit.SmtpClient` protocol + `LiveSmtpClient` actor — submission over implicit TLS on port 465 (the submission listener in `terraform/infra/modules/elb/main.tf` binds both 587 and 465; 465 sidesteps `NWConnection`'s lack of STARTTLS upgrade support). AUTH PLAIN against the same Cognito credentials Dovecot uses, RFC 5322 message assembly via `MessageBuilder` (multipart/alternative, multipart/mixed with attachments, RFC 2047 header encoding, RFC 2045 base64 wrapping, RFC 5321 dot-stuffing).
  - `CabalmailKit.EnvelopeCache` — per-folder JSON snapshot keyed by UIDVALIDITY, sized for the "STATUS + UID FETCH since UIDNEXT" reconnect flow from the plan.
  - `CabalmailKit.MessageBodyCache` — disk-backed LRU for `BODY.PEEK[]` payloads with a configurable byte cap (default 200 MB), evicting by file mtime.
  - `CabalmailKit.AddressCache` — in-memory actor mirroring the React app's `localStorage[ADDRESS_LIST]` invalidation pattern.
  - `CabalmailClient` actor rebuilt as the top-level facade: owns the auth session and exposes every service + cache; `CabalmailClient.make(configuration:secureStore:...)` wires production against the real Cognito/API/IMAP/SMTP tiers in one call.
  - `CabalmailKit` test target coverage for: Cognito sign-in happy path and refresh-on-expired, `NotAuthorizedException` mapping, `ApiClient` token attachment and 401→refresh→retry behavior, IMAP LIST/STATUS/FETCH-with-literal/STORE/MOVE-with-fallback + folder-delimiter translation, SMTP AUTH-failure mapping and dot-stuffing, and the IMAP response parser across tagged/untagged/FETCH/SEARCH shapes.
- **Apple client Phase 4 — Mail Reading** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.ConfigLoader` — fetches `/config.json` from a user-supplied control domain. The sign-in form passes the domain once; subsequent launches reuse the cached `Configuration` so the same binary works against dev/stage/prod.
  - `CabalmailKit.MimeParser` — hand-rolled multipart tree walk over raw `BODY.PEEK[]` bytes. Decodes RFC 2045 `Content-Type` / `Content-Disposition` / `Content-Transfer-Encoding` parameters, traverses arbitrarily-nested `multipart/*`, and exposes leaf parts, attachment candidates, and a `cid:` → decoded-body map for inline images.
  - `CabalmailKit.MimeDecoders` — quoted-printable and base64 body decoders; lenient on malformed input so one broken part doesn't blank the whole message.
  - `CabalmailKit.HeaderDecoder` — RFC 2047 encoded-word decoder (UTF-8 / ISO-8859-1 / Windows-1252 / US-ASCII; Q and B), including the §6.2 rule that whitespace between adjacent encoded-words is stripped.
  - 9 new `MimeParserTests` cover plain text, base64 bodies, quoted-printable with soft-break and hex escapes, `multipart/alternative`, `multipart/mixed` with attachments, encoded-word headers, mixed-encoding header values, and folded-header unfolding. Total `CabalmailKit` tests: 39 (was 30).
  - App target (`apple/Cabalmail/`): `AppState` (`@Observable @MainActor`) as the root state; `SignInView` (control domain + user/pass); `FolderListView` with per-folder `STATUS (UNSEEN)` badges, Inbox-pinned-first ordering, and pull-to-refresh; `MessageListView` with UIDNEXT-based sliding-window fetch, on-scroll pagination, `.searchable` wired to IMAP `UID SEARCH`, swipe-to-archive / swipe-to-flag; `MessageDetailView` with headers block, body renderer, attachment strip, and a toolbar "Load remote content" toggle; `HTMLBodyView` wrapping `WKWebView` with non-persistent data store, JS disabled, and a `WKNavigationDelegate` that rejects every non-`file://` / non-`data:` request unless the user has flipped the toggle; `AttachmentStrip` opens downloads via `QLPreviewController` on iOS / visionOS and `NSWorkspace.open(_:)` on macOS.
  - `MailRootView` branches on horizontal size class: iPhone gets a `NavigationStack` (folder → messages → detail), iPad / macOS / visionOS get a three-column `NavigationSplitView`.
  - macOS target (`apple/CabalmailMac/`): now shares the iOS view sources via `project.yml` (`Cabalmail/ContentView.swift`, `Cabalmail/AppState.swift`, `Cabalmail/Views/`, `Cabalmail/ViewModels/`). The Phase 1 "separate views per target" decision relaxed to "shared SwiftUI, separate bundles + entry points"; the Settings scene and hardened-runtime entitlement stay macOS-only.
  - Root envelope-list cache integration: `MessageListViewModel` hydrates from `EnvelopeCache` on open (so reopen is instant), merges refreshed envelopes back, and invalidates both caches on a `UIDVALIDITY` change. `MessageDetailViewModel` consults `MessageBodyCache` before issuing `UID FETCH BODY.PEEK[]`.
- **Apple CI hardening — manual code signing for archive + export:**
  - Both `upload-ios` and `upload-mac` archive steps now sign manually (`CODE_SIGN_STYLE=Manual`, `PROVISIONING_PROFILE_SPECIFIER=<UUID>`, `CODE_SIGN_IDENTITY="Apple Distribution"`) against a provisioning profile installed from a new per-target GitHub secret. `-allowProvisioningUpdates` and the `-authenticationKey*` args are dropped from `xcodebuild archive` and `exportArchive`; auto-provisioning never touches Development certs, so Apple's per-team cert cap no longer fails the build.
  - New composite action `.github/actions/install-provisioning-profile` decodes a base64-encoded profile (iOS `.mobileprovision` or macOS `.provisionprofile`) into `~/Library/MobileDevice/Provisioning Profiles/`, reads the UUID from the CMS-signed plist, and exports it via `$GITHUB_ENV` so the archive step can reference it as `PROVISIONING_PROFILE_SPECIFIER`.
  - Export-options plists are now generated at CI time via heredoc with the profile UUID embedded in `provisioningProfiles`; the static `apple/ci/ExportOptions-*.plist` files are removed. Removes the risk of archive-vs-export profile drift.
  - Mac App Store `.pkg` signing: the `upload-mac` job now imports a **Mac Installer Distribution** cert alongside the Apple Distribution cert (the outer `.pkg` wrapper needs its own cert), and the generated export-options plist references it via `installerSigningCertificate = "3rd Party Mac Developer Installer"`. New required secrets: `MAC_INSTALLER_CERT_P12` / `MAC_INSTALLER_CERT_PASSWORD`. The keychain password is now persisted to `$RUNNER_TEMP/keychain-password` (chmod 600) so the optional Developer ID import later in the same job can unlock the same keychain.
  - `CURRENT_PROJECT_VERSION` is now a Unix timestamp (`date -u +%s`) rather than `github.run_number`. `CFBundleVersion` must be strictly monotonic per marketing version across everything that has ever uploaded to the App Store Connect record, and `run_number` can drift below the highest previously-uploaded build (e.g. after a workflow rename). Timestamps are always higher than the last upload.
  - New required secrets: `IOS_APP_STORE_PROFILE` (gates `upload-ios`), `MAC_APP_STORE_PROFILE` + `MAC_INSTALLER_CERT_P12` + `MAC_INSTALLER_CERT_PASSWORD` (gate `upload-mac`), and optionally `MAC_DEVID_PROFILE` (paired with `DEVELOPER_ID_CERT_P12` to produce the notarized direct-distribution artifact; missing either pair member skips that artifact cleanly).
  - App Store Connect API key role can drop from **Admin** to **App Manager** — CI no longer calls the profile-creation API. Documented in `apple/README.md`.
- **Apple client Phase 5 — Mail Composition & On-the-Fly From** (`docs/0.6.0/ios-client-plan.md`):
  - `CabalmailKit.ReplyBuilder` — pure value-type helper that turns an `Envelope` + its decoded plain-text body + the user's owned addresses into a seeded `Draft`. Implements idempotent `Re:` / `Fwd:` subject prefixing, `In-Reply-To` / `References` threading, reply-all deduplication and self-exclusion, reply-attribution + `>`-prefixed quoting, forward-banner quoting, and the "default From to the original's addressee" rule that makes the per-correspondent address minted for one reply reusable across the whole thread.
  - `CabalmailKit.Draft` + `CabalmailKit.DraftStore` — Codable model and atomic on-disk store (`{cacheDirectory}/drafts/{uuid}.json`) with corrupt-file recovery. `ComposeViewModel` autosaves every 5 s while the sheet is open so a mid-compose app kill is recoverable.
  - `CabalmailClient.send(_:)` facade — stamps a shared `Message-ID`, submits the payload via SMTP, then best-effort-`APPEND`s the identical payload to the `Sent` IMAP folder with `\Seen` set. Matches the React app's `send` Lambda behavior so both clients produce the same Sent-folder view; a failed APPEND after a successful submission does not surface as a send error.
  - `OutgoingMessage.messageId` — optional, lets the sender supply a pre-generated Message-ID so the Sent copy and the wire copy thread as one message.
  - App target: `Cabalmail/Views/ComposeView.swift` (SwiftUI form sheet — From picker, To/Cc/Bcc token fields, Subject, plain-text `TextEditor`, attachment strip, Cancel/Attach/Send toolbar, discard-draft confirmation); `Cabalmail/Views/FromPicker.swift` (Menu with "**Create new address…**" as the first, always-visible item per the Cabalmail on-the-fly-From idiom, alphabetized existing addresses below); `Cabalmail/Views/NewAddressSheet.swift` (inline address-creation form mirroring `react/admin/src/Addresses/Request.jsx`, including the Random button); `Cabalmail/ViewModels/ComposeViewModel.swift` (state, autosave loop, send/cancel/discard flows, `canSend` gating, PhotosPicker + fileImporter ingestion).
  - `MessageDetailView` gains a Reply / Reply All / Forward menu in its toolbar; `MessageListView` gains a New Message toolbar button. Both present the same `ComposeView` sheet, differentiated only by the `Draft` seed passed in (`ReplyBuilder.build(from:body:mode:userAddresses:)` vs `ReplyBuilder.newDraft()`).
  - `CabalmailKit` test coverage: 12 `ReplyBuilderTests` (subject prefixing idempotence, default-From selection from owned addresses including case-insensitive match and "no owned match → nil" fallthrough, reply-to-list primary/cc split, reply-all dedup + self-exclusion, Reply-To-over-From precedence, forward-has-no-recipients, reply-body `>` quoting + attribution line, forward banner, threading-headers with and without the original's In-Reply-To, ReplyBuilder → OutgoingMessage → MessageBuilder integration asserting the wire payload includes the right `In-Reply-To` / `References` / `Re:` subject); 8 `DraftStoreTests` (round-trip, empty-draft-not-persisted, empty-draft-cleans-stale-file, list-sorted-newest-first, remove, corrupt-file-skipped-and-removed, load-missing-returns-nil, save-replaces-existing). Total `CabalmailKit` tests: 59 (was 39).
  - `CabalmailClient` stored properties marked `nonisolated` (immutable, `Sendable`) so SwiftUI views can read `client.configuration.domains` and other references synchronously — mutating flows still funnel through the actor's methods.

### Changed

- **Let's Encrypt production CA in every environment.** `lambda/certbot-renewal/handler.py` no longer branches on `USE_STAGING`, and the `certbot_renewal` Terraform module drops its `prod` input variable. Staging certs (previously used for non-prod environments) aren't trusted by iOS/macOS root stores, so an Apple client hitting `smtp-out.<control_domain>` on port 465 (TCP passthrough, Dovecot presents the Let's Encrypt cert directly) couldn't complete the implicit-TLS handshake. The certbot Lambda re-issues against production on its next run; force a manual invocation after deploy if you want the swap immediately rather than on the scheduled renewal.
- **Certbot Lambda `image_uri` rotates per deploy.** The module had `image_uri = "${repo_url}:latest"` hardcoded, which Terraform treats as a string that never changes — the Lambda kept running whichever image had been pushed the first time it was created, even when CI pushed a new `:latest` tag. The module now takes an `image_tag` input wired from `/cabal/deployed_image_tag` (the same SSM parameter the ECS task definitions consume), so the Lambda's image reference rotates on every deploy.

## [0.5.0] - Unreleased

### Added

- **Admin dashboard with user management (Phase 1 of `docs/0.5.0/user-management-plan.md`):**
  - Cognito admin group (`aws_cognito_user_group "admin"`) with master user placed in it via `aws_cognito_user_in_group`
  - 5 new admin-only Lambda functions: `list_users`, `confirm_user`, `disable_user`, `enable_user`, `delete_user`
  - Lambda IAM policy extended with Cognito permissions (`ListUsers`, `AdminConfirmSignUp`, `AdminDisableUser`, `AdminEnableUser`, `AdminDeleteUser`) scoped to the user pool ARN
  - `USER_POOL_ID` env var added to all Lambda functions
  - `ApiClient` methods: `listUsers`, `confirmUser`, `disableUser`, `enableUser`, `deleteUser`
  - React `Users` tab — lists pending and confirmed users with Confirm/Disable/Enable/Delete actions; visible only to members of the admin group (detected via the `cognito:groups` JWT claim)
  - React `Dmarc` tab placeholder (wired into routing for Phase 3)
  - Admin-gated nav visibility via `is-admin` CSS class
  - Self-deletion guard in `delete_user`
  - Master system account filtered from the Users view so it cannot be modified
- **DMARC report ingestion and display (Phase 3 of `docs/0.5.0/user-management-plan.md`):**
  - `dmarc` system Cognito user (osid=9998) with a dedicated mailbox, address `dmarc-reports@mail-admin.<first-mail-domain>` created in `cabal-addresses`, and DNS records for the `mail-admin` subdomain (MX/SPF/DKIM/DMARC CNAMEs)
  - Global DMARC DNS record updated to use the configured mail domain instead of a hardcoded value
  - DynamoDB table `cabal-dmarc-reports` (composite key: `header_from#date_end` / `source_ip#report_id`, PITR, server-side encryption)
  - `process_dmarc` Lambda (Python 3.13, arm64, 512MB, 120s) — authenticates to IMAP via the master-user pattern (`dmarc*admin`), fetches the `dmarc` inbox, parses zip/gzip/raw XML DMARC aggregate reports (RFC 7489), writes records to DynamoDB in batches, then moves processed messages to `INBOX.Processed`
  - Handles RFC 2047 encoded-word attachment filenames and `application/octet-stream` attachments from mail clients that don't set specific MIME types
  - EventBridge Scheduler triggers `process_dmarc` every 6 hours with a flexible 30-minute window
  - `list_dmarc_reports` admin-only Lambda — paginated DynamoDB scan with base64-encoded `next_token`
  - `ApiClient.listDmarcReports(nextToken)` method
  - React `Dmarc` tab — full implementation with org/domain/source IP/count/disposition/DKIM/SPF columns, color-coded pass/fail badges, refresh button, and "Load more" pagination
  - `dmarc` system user filtered from the Users admin view (same pattern as `master`)
- Mobile hamburger menu — below 959px (covers portrait and landscape phones) the nav tabs collapse into a hamburger dropdown so admin tabs like DMARC stay reachable on narrow screens
- **Multi-user address management (Phase 4 of `docs/0.5.0/user-management-plan.md`):**
  - Surfaces the latent multi-user delivery already supported by `docker/shared/generate-config.sh` (slash-separated `user` field expanded via `/etc/aliases.dynamic`)
  - 4 new admin-only Lambda functions: `assign_address` (PUT), `unassign_address` (PUT), `new_address_admin` (POST), `list_addresses_admin` (GET)
  - Cognito `AdminGetUser` added to the shared Lambda IAM policy so admin endpoints can validate that target users exist before writing
  - `assign_address`/`unassign_address`/`new_address_admin` all publish to the existing address-change SNS topic to trigger container reconfiguration, matching the `new`/`revoke` pattern
  - `unassign_address` refuses to remove the last user from an address (use `revoke` to delete instead)
  - `ApiClient` methods: `listAllAddresses`, `assignAddress`, `unassignAddress`, `newAddressAdmin`
  - Admin-only "All Addresses" tab in the Addresses view (`Addresses/Admin.jsx`) — filter/search, New Address form with multi-user assignment checkboxes, per-row chips showing assigned users with inline × removal, and a "+ User" picker to assign additional users
  - Confirmed users in the Users tab now display their assigned addresses as chips, with inline × removal on shared addresses and a "+ Address" picker to assign existing addresses to a user
  - Hover/tap on a shared-address chip in the Users tab highlights identical chips under other users (tap toggles a sticky highlight on touch devices)
  - `master` and `dmarc` system users excluded from the admin Assign-to picker

### Fixed

- `SignUp` form inputs were uncontrolled — App.jsx now passes `username`, `password`, and `phone` props so typing is reflected in the SignUp form instead of leaking into Login's shared state
- Stale per-user cache after logout — `ADDRESS_LIST`, `FOLDER_LIST`, and `INBOX` localStorage keys are now cleared in `doLogout`, preventing the next user from seeing the previous user's folders and addresses
- DMARC report list couldn't be scrolled when long because `Email.css` globally sets `body` to `position: absolute; overflow: hidden`; scoped `overflow: auto` and `max-height` to `div.App div.Dmarc` so it scrolls independently
- Nav dropdown was hidden on the Email tab because `div.email_list` has `z-index: 99999`; raised the nav's `z-index` to `100000` so the hamburger menu stays above view-level overlays
- `lambda/api/list` filter was an exact match on the `user` field, so callers who were one of several users on a multi-user address lost it from their "My Addresses" view — switched to a `contains()` DynamoDB scan filter plus a Python slash-split membership check (avoids false positives like `chris` matching `christopher`)
- API Gateway was caching `/list` for 60 seconds, serving stale results after admin-side address assignment changes — disabled the Gateway cache on `/list`
- Client-side `ADDRESS_LIST` localStorage cache not invalidated by admin address-mutation endpoints — `assignAddress`, `unassignAddress`, and `newAddressAdmin` now bust it

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

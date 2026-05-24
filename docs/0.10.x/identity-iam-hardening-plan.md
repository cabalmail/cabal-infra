# Identity and IAM Hardening Plan

## Context

Cabalmail's identity and authorisation story is layered: Cognito authenticates users into the admin app and into IMAP/SMTP (via master-user + per-user OS account); API Gateway brokers Lambda invocations on Cognito JWTs; per-Lambda IAM roles bound the blast radius of any single function compromise. The layering is sound. The current configuration of each layer has drifted from defensible defaults over the project's lifetime — small omissions that individually look harmless and together leave the system more permissive than the design intent.

This audit pass found three clusters:

1. **Cognito posture.** No MFA is configured. No advanced security mode. Account recovery is SMS-only — a single SIM-swap away from account takeover, and a single lost phone away from a permanent lockout. Refresh tokens default to a 30-day lifetime with no rotation policy. Email is not auto-verified; phone is, by virtue of the SMS-only signup flow.
2. **API Gateway logging and auth caching.** `data_trace_enabled = true` with `logging_level = "INFO"` means CloudWatch receives full request and response bodies — including the contents of every email body fetched via `/fetch_message`, every attachment metadata payload, every preference write. The default authorizer cache (300 s) means a revoked token stays usable for up to 5 minutes after invalidation. Method-level cache TTL on some user-personalised endpoints exceeds the authorizer cache.
3. **Lambda IAM blast radius.** Several roles use the `arn:aws:<service>:REGION:ACCOUNT:<resource-type>/${local.wildcard}` pattern, where `local.wildcard = "*"`. The wildcard satisfies the IaC scanners (the literal string `"*"` is what they look for) but the *effect* is account-wide. Notably the `assign_osid` Lambda can call `AdminUpdateUserAttributes` on any user pool in the account, and the `certbot_renewal` Lambda has `route53:ListHostedZones` on `Resource: "*"`.

The plan addresses each cluster in its own phase. The Cognito work is the most user-visible — adding TOTP, requiring email verification, enabling adaptive auth — and gets the most operator-side documentation cost. The API Gateway change is the highest-impact security fix per LOC: turning off the data trace silently removes the leakiest log stream in the system.

## Goals

- Every Cognito user has the option of TOTP-based MFA; admin users have it required.
- Account recovery offers email as a fallback alongside phone, so a lost or rotated phone does not permanently lock a user out and a SIM swap cannot single-factor take an account.
- Adaptive authentication (Cognito Advanced Security) is enabled in audit mode at minimum; risk-flagged events route to a per-environment log group with a CloudWatch alarm on `risk = High`.
- Refresh tokens expire in 7 days, not 30. Token rotation is enabled. A compromised refresh token has a bounded lifetime.
- API Gateway no longer logs request/response bodies. Authorizer cache TTL drops from 300 s to 60 s — a token revoked in Cognito is unusable against the API within one minute.
- Every Lambda IAM role names the exact resource ARNs it needs. No wildcards except where AWS service grammars require them (e.g., `route53:ListHostedZones` which has no resource-level grammar).
- ECR repositories have `scan_on_push = true` and `image_tag_mutability = "IMMUTABLE"`. Scan findings populate the GitHub Security tab via the same SARIF surface as the IaC scanners.

## Non-goals

- Replacing Cognito. The migration cost is enormous and the gains are mostly cosmetic. Cognito's edges are managed by configuration, not replacement.
- Per-Lambda audit logging beyond the structured-log additions captured in [`application-surface-hardening-plan.md`](./application-surface-hardening-plan.md).
- A standalone OIDC IdP. Cognito IS the OIDC provider; the front-door ALB authenticate-oidc action already consumes it via the hosted-UI domain.
- WAF in front of API Gateway. Worth doing eventually, but the per-Lambda rate-limit work in [`application-surface-hardening-plan.md`](./application-surface-hardening-plan.md) Phase 5 covers the high-leverage attack patterns; WAF is a follow-on once we have per-endpoint signal.
- Federated identity (Google, Apple, etc. as IdPs). Out of scope; covered by [`docs/0.6.x/`](../0.6.x/) where applicable.
- Cross-account IAM (separating CI/CD principals from runtime principals into a dedicated DevOps account). Worth doing; out of scope here.
- Per-user encryption keys (KMS-per-user for stored message bodies). Architectural — not 0.10.x.

## Current state (audit)

### Cognito

[`terraform/infra/modules/user_pool/main.tf:5-36`](../../terraform/infra/modules/user_pool/main.tf):

- `auto_verified_attributes = ["phone_number"]`. Email is not auto-verified.
- `sms_configuration` is set; no `software_token_mfa_configuration`. SMS is the only second-factor option, and it is not required.
- `account_recovery_setting` lists only `verified_phone_number`.
- No `mfa_configuration` attribute — defaults to `"OFF"`. MFA cannot even be enabled by a user who wants it; the pool refuses.
- No `user_pool_add_ons { advanced_security_mode = ... }`. Adaptive authentication is off.

[`terraform/infra/modules/user_pool/main.tf:74-80`](../../terraform/infra/modules/user_pool/main.tf):

- `access_token_validity = 12` (hours). Reasonable.
- `id_token_validity = 12` (hours). Reasonable.
- `refresh_token_validity` is not set — defaults to 30 days.
- `token_validity_units` is not set — defaults are `hours` for access/id and `days` for refresh.
- `enable_token_revocation` is not set — defaults to `true` per AWS docs, but explicit is better.

### API Gateway

[`terraform/infra/modules/app/main.tf:134-146`](../../terraform/infra/modules/app/main.tf):

- `data_trace_enabled = true`. The AWS docs explicitly say "not recommended for production." Logs include full request bodies (passwords, JWTs, email contents, attachments — anything passing through the gateway).
- `logging_level = "INFO"`. Combined with `data_trace_enabled`, every API call writes a multi-KB log line.
- `throttling_rate_limit = 100`, `throttling_burst_limit = 50`. Stage-wide; no per-method overrides.

[`terraform/infra/modules/app/main.tf:148-...`](../../terraform/infra/modules/app/main.tf) for `aws_api_gateway_method_settings.cache_settings`:

- Per-method `caching_enabled = each.value.cache` and `cache_ttl = 3600` (1 hour) on cached methods. Authorizer cache TTL is not set (defaults to 300 s). Any caller whose token is invalidated mid-cache-window can still hit the cached method response for up to 1 hour.

Authorizer config: [`terraform/infra/modules/app/main.tf` around the `aws_api_gateway_authorizer` resource]. No `authorizer_result_ttl_in_seconds` override. Default is 300 s.

### Lambda IAM

[`terraform/infra/modules/user_pool/counter.tf:7`](../../terraform/infra/modules/user_pool/counter.tf): `wildcard = "*"`. Used at line 44 to form `arn:aws:cognito-idp:REGION:ACCOUNT:userpool/*`. The Lambda can `AdminUpdateUserAttributes` any user in any pool in the account.

Similar pattern at:

- [`terraform/infra/modules/user_pool/check_invite.tf:76`](../../terraform/infra/modules/user_pool/check_invite.tf) — logs group wildcard, low impact.
- [`terraform/infra/modules/certbot_renewal/iam.tf:55-60`](../../terraform/infra/modules/certbot_renewal/iam.tf) — `route53:ListHostedZones*` on `Resource: "*"`. Service-level required by AWS (no resource grammar for List ops).
- [`terraform/infra/modules/ecs/iam.tf:115-121`](../../terraform/infra/modules/ecs/iam.tf) — `ssmmessages:*` on `Resource: "*"`. Required by the service for ECS Exec.
- [`terraform/infra/modules/user_pool/iam.tf:22`](../../terraform/infra/modules/user_pool/iam.tf) — `sns:Publish` on `Resource: "*"`. The Cognito-SMS role; SNS Publish for SMS goes through the platform endpoint, no specific topic ARN.

The four "service requires wildcard" cases are fine; the `userpool/*` case is the one that should be specific.

### ECR

[`terraform/infra/modules/ecr/main.tf`](../../terraform/infra/modules/ecr/main.tf): repositories created without `image_scanning_configuration`, without `image_tag_mutability`, without a repository policy. Defaults are scan-off, tag-mutable, any-principal-in-account.

## Target state

### Phase 1 — Cognito MFA (TOTP) and recovery posture

[`terraform/infra/modules/user_pool/main.tf`](../../terraform/infra/modules/user_pool/main.tf) gains:

```hcl
resource "aws_cognito_user_pool" "users" {
  ...
  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
    recovery_mechanism {
      name     = "verified_phone_number"
      priority = 2
    }
  }

  auto_verified_attributes = ["email", "phone_number"]
}
```

For admins specifically (the `cabal-admin` user group): a Lambda pre-token-generation trigger refuses to issue tokens to admin-group members whose `MFAEnabled` Cognito attribute is `false`. Mechanically that's a second small Lambda (`require_admin_mfa`) hung off the pool's `pre_token_generation` slot.

Updated React signup flow: collect email at signup time, send a verification email, gate the welcome screen on email confirmation. The Apple client likewise.

User-facing migration: existing users get an email on next signin saying "please verify your email address" with a one-click link. SMS-only users keep working; they just gain a fallback.

### Phase 2 — Cognito advanced security + token TTL

```hcl
resource "aws_cognito_user_pool" "users" {
  ...
  user_pool_add_ons {
    advanced_security_mode = "AUDIT"   # promoting to "ENFORCED" is Phase 2.5
  }
}

resource "aws_cognito_user_pool_client" "users" {
  ...
  refresh_token_validity = 7
  access_token_validity  = 12
  id_token_validity      = 12

  token_validity_units {
    refresh_token = "days"
    access_token  = "hours"
    id_token      = "hours"
  }

  enable_token_revocation = true
}
```

Advanced security in `AUDIT` mode is free (per AWS pricing) and emits risk-score events into a CloudWatch metric stream. Phase 2.5 promotes to `ENFORCED` after a soak period during which we collect false-positive rates. `ENFORCED` is the right end state for a primary mailbox; do not skip the audit phase.

The 7-day refresh-token lifetime means anyone whose laptop is stolen has 7 days of bounded exposure rather than 30. React and Apple clients both transparently re-auth at refresh expiry — no UX work needed.

### Phase 3 — API Gateway logging and authorizer cache

[`terraform/infra/modules/app/main.tf`](../../terraform/infra/modules/app/main.tf):

```hcl
resource "aws_api_gateway_method_settings" "general_settings" {
  ...
  settings {
    metrics_enabled        = true
    data_trace_enabled     = false       # was true
    logging_level          = "ERROR"     # was INFO
    throttling_rate_limit  = 100
    throttling_burst_limit = 50
  }
}

resource "aws_api_gateway_authorizer" "cognito" {
  ...
  authorizer_result_ttl_in_seconds = 60
}
```

The access log format (separate setting on the stage) is left intact — it captures source IP, caller identity, method, path, status, latency. That is the right amount of information to keep.

Method-level cache TTLs on user-personalised endpoints (`/fetch_message`, `/list_envelopes`, `/fetch_attachment`, `/fetch_inline_image`) drop from `3600` to `0` (disabled). The Lambda S3-cache layer in `_shared/helper.py` already covers the dominant cache concern (body re-fetches); API Gateway caching atop it provides little additional benefit and creates the cache-vs-authz drift documented in the audit. Non-personalised cached endpoints (`/list_my_domains`, BIMI fetches) keep their cache TTL.

The CloudWatch log group for API Gateway access logs has its retention set explicitly in Terraform (it is today; verify the value is reasonable — 14 days is the project default and matches the rest of the log groups). The execution-logs group, now emitting only `ERROR`, can stay at 14 days as well.

### Phase 4 — Lambda IAM resource narrowing

[`terraform/infra/modules/user_pool/counter.tf:44`](../../terraform/infra/modules/user_pool/counter.tf):

```hcl
{
  Effect   = "Allow"
  Action   = "cognito-idp:AdminUpdateUserAttributes"
  Resource = aws_cognito_user_pool.users.arn   # was userpool/${local.wildcard}
}
```

The change is name-only; the Lambda already accesses only this pool at runtime. Wildcard was a Terraform shape, not a runtime intent.

Same audit pass against every Lambda in `terraform/infra/modules/` and `terraform/infra/modules/app/modules/`. The pattern is mechanical: where `local.wildcard` resolves to a resource ID, replace with the specific ID; where it resolves to the service grammar's required `*` (logs streams, SSM Messages, SNS Publish, Route53 List*), keep with a code comment saying so.

A small CI helper script (`.github/scripts/check-iam-resource-scope.py`) flags any `Resource = "*"` or `Resource` containing the literal string `local.wildcard` without an accompanying `tfsec:ignore` or `checkov:skip` comment with rationale. Picked up by the Phase 3 suppression-justification check in [`iac-quality-gates-plan.md`](./iac-quality-gates-plan.md).

### Phase 5 — ECR posture

[`terraform/infra/modules/ecr/main.tf`](../../terraform/infra/modules/ecr/main.tf): each `aws_ecr_repository` resource gains:

```hcl
image_tag_mutability = "IMMUTABLE"

image_scanning_configuration {
  scan_on_push = true
}
```

A repository policy that restricts pull to the ECS execution role and the CI deploy principal:

```hcl
resource "aws_ecr_repository_policy" "tier" {
  for_each   = aws_ecr_repository.tier
  repository = each.value.name
  policy     = data.aws_iam_policy_document.ecr_repo[each.key].json
}
```

`scan_on_push = true` produces findings; the rollout pattern mirrors [`iac-quality-gates-plan.md`](./iac-quality-gates-plan.md) Phase 2 (baseline current findings, accept them as known, fail on new). Image-scan output uploads to GitHub Code Scanning via SARIF.

`image_tag_mutability = "IMMUTABLE"` means re-tagging a SHA-tagged image fails. The deploy script in [`container-runtime-hardening-plan.md`](./container-runtime-hardening-plan.md) Phase 3 moves to digest references, sidestepping the mutability concern at the consumer side.

## Migration sequence

| Phase                                  | Scope                                     | User-visible | Risk                                                                                                                                                                                                                                                                                                                                                          |
| -------------------------------------- | ----------------------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 — Cognito MFA + email recovery       | user_pool module, react admin, apple kit  | Yes          | Medium. UX change; needs a clear migration message to existing users. Test by going through the signup flow end-to-end with TOTP enabled.                                                                                                                                                                                                                     |
| 2 — Advanced security + 7-day refresh  | user_pool module                          | Mostly no    | Low. Refresh-token TTL change forces a re-auth after 7 days instead of 30 — invisible to anyone using the app weekly.                                                                                                                                                                                                                                         |
| 3 — API Gateway logging + authz cache  | app module                                | No           | Low. The data_trace change is purely subtractive (less logging). The authorizer cache TTL change shortens the window between Cognito revoke and API refuse — opposite of regression.                                                                                                                                                                          |
| 4 — IAM resource narrowing             | many modules                              | No           | Low. The wildcard-to-specific mapping is mechanical; each individual change is reversible. A regression would surface as a runtime AccessDenied error in CloudWatch.                                                                                                                                                                                          |
| 5 — ECR scan-on-push + immutable tags  | ecr module, deploy script                 | No           | Medium. Tag immutability requires the digest-pin work from [`container-runtime-hardening-plan.md`](./container-runtime-hardening-plan.md) Phase 3 to land first; sequence accordingly.                                                                                                                                                                          |

Per-environment ordering: dev → stage → prod for each phase, with at least one normal deploy cycle between flips so issues surface cheaply.

Phase 1 and Phase 5 have inter-plan dependencies (Apple/React client work; container-plan digest work). Phase 2, 3, 4 are independent of each other and of the other plans; they can ship in any order.

## Rollback

| Phase | Rollback                                                                                                                                                                                                                                                |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Set `mfa_configuration = "OFF"`, drop `software_token_mfa_configuration`, restore SMS-only recovery. Existing TOTP secrets in the user pool remain but are not consulted. No data loss.                                                                  |
| 2     | Set `advanced_security_mode = "OFF"`, drop `refresh_token_validity` (returns to default 30 d).                                                                                                                                                          |
| 3     | Set `data_trace_enabled = true`, `logging_level = "INFO"`, `authorizer_result_ttl_in_seconds = 300`. Per-method cache TTLs restored from git.                                                                                                            |
| 4     | Revert the specific Resource ARNs to the wildcard shape. The CI scope check stays in place but only fails on new wildcards.                                                                                                                              |
| 5     | `image_tag_mutability = "MUTABLE"`, `scan_on_push = false`, remove the repository policy. Existing images remain.                                                                                                                                       |

## CI changes

- [`.github/workflows/infra.yml`](../../.github/workflows/infra.yml) gains the `check-iam-resource-scope.py` step (Phase 4). Wired into the same scanner job structure as the Phase 3 Checkov/tflint/Trivy work in [`iac-quality-gates-plan.md`](./iac-quality-gates-plan.md).
- [`.github/workflows/app.yml`](../../.github/workflows/app.yml) consumes the ECR scan-on-push findings via `aws ecr describe-image-scan-findings` and uploads SARIF (Phase 5).
- The React signup flow change (Phase 1) lands in [`react/admin/`](../../react/admin/) and is built/deployed by the existing app.yml React-bundle path.
- The Apple kit change (Phase 1) lands in [`apple/CabalmailKit/`](../../apple/CabalmailKit/) and is exercised by `swift test`.

## Acceptance

- A new user signing up via the React admin app is prompted to verify email *and* phone. The signup flow does not complete until both are verified.
- A user enrolling TOTP via Cognito's hosted UI (or via the React app's MFA enrolment screen) receives a QR code, completes the enrolment, and is required to enter a TOTP code on next login.
- An admin user without MFA enrolled is rejected at token-issuance time (the `require_admin_mfa` trigger returns an error). The React admin app displays a "Please enrol MFA before continuing" screen.
- A user who has lost their phone can request account recovery via the verified email address and complete the flow without operator intervention.
- A refresh-token issued on day 1 fails to refresh on day 8 with `NotAuthorizedException`. The client transparently re-auths.
- Cognito CloudWatch metrics show `Risk = High` events for impossible-travel scenarios (synthesize via VPN test). An alarm fires.
- `aws apigateway get-stage --rest-api-id <id> --stage-name <stage>` returns `dataTraceEnabled: false` and `loggingLevel: ERROR`.
- A token revoked via `aws cognito-idp admin-user-global-sign-out` is rejected by the API within 60 seconds (verified by hammering an endpoint with a previously-valid token and observing the 401).
- The `assign_osid` Lambda's IAM policy contains the specific `aws_cognito_user_pool.users.arn` value, no `*` segment.
- ECR `describe-repositories` shows `imageTagMutability: IMMUTABLE` and `imageScanningConfiguration: {scanOnPush: true}` for every Cabalmail repository.
- A push to ECR that retags an existing SHA fails with `TagAlreadyExistsException`.

## Open questions

- **TOTP-required for non-admins.** Phase 1 makes TOTP optional for all and required for admins. A future phase could require it for all users; the trade-off is operational burden (lost-phone tickets) versus security floor. Defer.
- **`ENFORCED` vs `AUDIT` for advanced security.** Phase 2 lands `AUDIT`; the promotion to `ENFORCED` (Phase 2.5) needs at least a week of data to calibrate the risk thresholds. Schedule the promotion as a separate PR after the soak.
- **Per-Lambda timeouts vs the global 30 s.** Today every Lambda has the call-module's default `timeout = 30`. Per-Lambda overrides would tighten the budget for endpoints that should be fast (`/folder_status`, `/list_my_domains`) and relax it for slow ones (`/process_dmarc`). Not strictly identity/IAM; flag for follow-up.
- **Cognito Hosted UI vs in-app login.** The admin app today implements its own login form using `amazon-cognito-identity-js`. Migrating to Hosted UI would centralise MFA UX, password-reset UX, and email/phone verification UX in Cognito's first-party flow. Larger change; flag for separate consideration.
- **JWT validation in the Apple client.** The Apple client trusts whatever JWT Cognito returned and uses it until refresh fails. Adding local-side `exp` checks and proactive refresh would smooth the UX after the 7-day refresh-window change. Out of scope here; track in the Apple client's own backlog.

## Out of scope for 0.10.x

- WAF in front of API Gateway.
- Cross-account IAM split (CI/CD principal isolated from runtime).
- Federated identity providers.
- Per-user KMS keys.
- Per-Lambda CodeSigningConfig (Lambda code-signing is a lever; not pulling it for 0.10.x).
- Replacing Cognito with a different IdP.

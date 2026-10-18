# AMR-Based MFA Assurance Plan

Per-request MFA assurance for the admin API surface, built on the `amr` claim Amazon Cognito is adding to its tokens. This plan was drafted in October 2026, ahead of the claim's availability; nothing in it can start before the Cognito rollout completes (see Timeline). A scheduled tickler re-opens it in March 2027.

## Progress

| Phase | Status |
|---|---|
| 0. Rollout verification on stage | **Blocked** until Cognito's claim rollout completes (2027-02-28); tickler scheduled for 2027-03-02 |
| 1. `amr` gate on the admin preamble (audit, then enforce) | Not started |
| 2. Enrollment-client token lockout (`aud` check) | Not started; implementable before Phase 0 if wanted — it does not depend on the new claims |
| 3. Step-up (`acr` / RFC 9470) and destructive user endpoints | Deferred, deliberately unscoped — see Non-goals |

## Context

AWS Health notice `AWS_COGNITO_OPERATIONAL_NOTIFICATION` (2026-10-15): Cognito is additively adding `amr` (authentication methods references, a JSON array of RFC 8176 method strings such as `["pwd", "otp", "mfa"]`) and `acr` (authentication context class reference, a `urn:cognito:loa:N` string) to the ID and access tokens of every user pool, plus matching OIDC discovery-metadata members. The rollout ramps gradually from 2026-11-04 and becomes the default for all pools by 2027-02-28. A compatibility audit of this repository (2026-10-18) found no component that parses tokens or discovery metadata strictly — every consumer reads claims by name and treats tokens as opaque — so the change itself requires nothing from us. This plan is about using the new information.

### The gap today

MFA enforcement lives in the `require_admin_mfa` pre-token-generation trigger ([lambda/counter/require_admin_mfa/function.py](../../lambda/counter/require_admin_mfa/function.py), Phase 1 of [docs/0.10.x/identity-iam-hardening-plan.md](../0.10.x/identity-iam-hardening-plan.md)). It gates token issuance on MFA *enrollment*, which is the strongest check available without an assurance claim, and it has three documented soft spots:

1. **`EXEMPT_USERS`** — service and machine accounts (master, the ci-probe user) authenticate with a password only and are passed silently. Their tokens are indistinguishable, at the API, from a human admin's.
2. **The `mfa_enroll` escape-hatch app client** — issues short-lived tokens to users with *no* factor so the locked-out setup flow can call AssociateSoftwareToken / VerifySoftwareToken / SetUserMFAPreference. Those are Cognito-side calls, but nothing stops the same tokens from being presented to our API Gateway, whose Cognito authorizer accepts tokens from any client of the pool. The "only intended use" in the trigger's docstring is intent, not enforcement.
3. **Enrollment is not use.** The trigger proves the caller *has* a factor at token-issuance time, not that this session *performed* MFA. Cognito itself demands the TOTP during the auth flow for enrolled users, so in practice the two coincide — but the API has no way to verify it, and fail-open paths in the trigger widen the gap by design.

`amr` closes (3) directly and gives (1) a per-token signal instead of a username list. (2) is closed by a plain `aud` check that needs no new claims at all; it rides along here because it serves the same goal and lands in the same code.

### Where the check sits

Every admin handler (16 at the time of writing) already runs `admin_response_or_none(event)` from [lambda/api/_shared/admin_limits.py](../../lambda/api/_shared/admin_limits.py) as its first statement — the Phase 5 preamble from the application-surface-hardening plan. One change there covers the entire admin surface, with tests in `lambda/api/_shared/tests/test_shared_admin_guard.py`.

The mail-flow and self-service endpoints (`send`, `move_messages`, `purge_messages`, `revoke`, …) are **not** gated by this plan. Two reasons: every human user is already MFA-enforced at sign-in (`ENFORCE_USER_MFA`), so an `amr` check there adds nothing for the normal case; and the post-deploy mail probe ([.github/scripts/mail-probe.py](../../.github/scripts/mail-probe.py)) is a password-only exempt account that calls `move_messages` and `purge_messages` on every deploy — gating those endpoints on MFA would break the probe, re-opening the #1739 tension the exemption list settled. If destructive user endpoints ever warrant more, the right shape is step-up (Phase 3), not a blanket gate.

## Design

### Phase 0: verify the claims on stage

Before any code, confirm on stage (read-only, using the shared tester account):

- `amr` is present on tokens from a TOTP sign-in and lists the expected methods. RFC 8176 names the values; expect password-plus-TOTP to carry `pwd`, `otp`, and the umbrella `mfa`, but record what Cognito actually emits rather than assuming.
- A password-only sign-in (the probe user's path) carries `amr: ["pwd"]` — the negative control.
- **Refresh-minted tokens carry the original sign-in's `amr`.** Every client refreshes hourly; if refresh were to drop or downgrade the claim, enforcement would intermittently lock out legitimately-MFA'd sessions. This is the single highest-risk unknown in the plan.
- **How API Gateway renders the claim.** The Cognito authorizer flattens claims into strings in `event.requestContext.authorizer.claims` — `cognito:groups` arrives as `"admin"`, `"admin,users"`, or `"[admin users]"` depending on shape, which is why `is_admin()` parses defensively. Capture the actual renderings of `amr` (likely `"[pwd otp mfa]"` or a JSON-ish string) from a real authorizer event, and pin them in tests.
- The `acr` values' semantics (`urn:cognito:loa:N`): record which level corresponds to MFA, for Phase 3's benefit. Prefer `amr` for Phase 1 regardless — it is self-describing where `acr` needs a mapping.

**Status:** Blocked until the rollout reaches our pools (default 2027-02-28). The 2027-03-02 tickler starts here.

### Phase 1: `amr` gate in `admin_response_or_none`

Add an MFA-assurance check to the admin preamble, directly after the group check:

- Parse the `amr` claim with the same whole-element tolerance as `is_admin()` (strip brackets and quotes, split on commas and whitespace, match whole elements — never substring). Treat the parsed set as satisfying assurance when it intersects the MFA method set (`mfa`, `otp`, `hwk`, `swk` — the Phase 0 capture finalizes this list).
- **Audit-by-default**, mirroring the `require_admin_mfa` flags: a new `ENFORCE_ADMIN_AMR` environment variable where anything but `"true"` logs a structured `would_block` line (reusing the `AUDIT` prefix convention) and allows the call. Soak in audit mode on stage for at least a week of real admin activity, then enforce on stage, then prod.
- In **enforce** mode, a missing or password-only `amr` returns 403 with a distinct message (`'MFA-verified session required'`), so a denial is distinguishable from a group denial in both the client and the audit log.
- A **missing claim denies in enforce mode.** By the time any environment enforces, the rollout is universal and every freshly-minted token carries the claim; a token without it is stale or anomalous. Audit mode is the mechanism that proves this safe before the flip — if audit logging shows legitimate claim-less tokens, enforcement waits.
- Expected blast radius: zero for legitimate use. Admin-group members have no MFA grace window, so every real admin session is TOTP-backed already; the gate converts an assumption into a check. The probe never calls admin endpoints. Whether any `EXEMPT_USERS` service account holds the admin group is exactly what the audit soak confirms.
- Tests in `test_shared_admin_guard.py`: the Phase 0 rendering variants, audit vs. enforce behavior, the missing-claim case in each mode, and a negative control (a `pwd`-only claim passing in audit mode must still log `would_block`).

**Status:** Not started.

### Phase 2: enrollment-client token lockout

Deny the API to tokens minted by the `mfa_enroll` app client, independent of `amr`: the ID token's `aud` claim is the app client id, the enroll client's id is already in SSM (`MFA_ENROLL_CLIENT_PARAM`), and the authorizer passes `aud` through like any claim.

- The admin surface gets it for free in the Phase 1 preamble change (check `aud` against the enroll client id alongside the `amr` check).
- The non-admin surface is the part that matters — enroll-client tokens belong to users with no factor at all — but handlers there read claims directly rather than through a shared preamble. Proposed shape: a small `helper.py` guard called from the existing per-handler claim read, adopted mechanically across handlers in one PR (helper.py is allowed to grow; the per-handler diff is two lines). The SSM read follows the same lazy, cache-on-success pattern as the trigger's.
- This phase needs none of the new claims and could ship any time; it is sequenced here only to land in the same code the Phase 1 work touches. If it ships first, it goes audit-mode-first the same way.

**Status:** Not started.

### Phase 3 (deferred): step-up and destructive user endpoints

`acr_values_supported` in the discovery document plus RFC 9470 (OAuth step-up challenge) would let the API answer a destructive call (`purge_messages`, `empty_trash`, a future bulk `revoke`) with `401` + `insufficient_user_authentication`, prompting the client to re-authenticate at a higher `acr` — fresh TOTP before the irreversible thing, rather than a blanket gate that breaks password-only service flows. That requires client-side work in all four client families and a Cognito `acr_values` request-parameter behavior we have not yet observed. Out of scope until there is a concrete need; this section exists so the context is not re-derived.

## Non-goals

- No change to sign-in flows, the `require_admin_mfa` trigger, or its exemption list.
- No gating of mail-flow or self-service endpoints (see Context for why).
- No consumption of the OIDC discovery document. (The auth-parity work may pick that up independently — the document now advertises PKCE S256 and grant types, which standard OIDC libraries self-configure from; see [auth-parity-plan.md](auth-parity-plan.md).)
- No `acr` enforcement anywhere in Phases 0–2.

## Timeline

| Date | Event |
|---|---|
| 2026-11-04 | Cognito begins ramping the new claims across pools |
| 2027-02-28 | Claims become the default for all user pools |
| 2027-03-02 | Scheduled tickler fires: run Phase 0, then decide on Phase 1 scheduling |

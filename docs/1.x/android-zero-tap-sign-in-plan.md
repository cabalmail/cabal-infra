# Android Zero-Tap Sign-In Plan

Restore the Android client's signed-in session when a user moves to a new Android device, as Google Play's Zero-Tap Sign-In requirement demands of every app with sign-in from April 2027. Tracking issue: [#2306](https://github.com/cabalmail/cabal-infra/issues/2306), which also carries a weekly scheduled watch on Google's still-unfinished policy text. This plan was drafted on 2026-11-01, before Google published the requirement's exceptions or its full details. Nothing in it depends on those details except one decision, called out under [Open questions](#open-questions).

## Progress

| Phase | Status |
|---|---|
| 0. Spike: device and Cognito unknowns | Not started |
| 1. Backend: restore keys, custom-auth triggers, restore client (inert) | arm64 build runners done (#2309); the rest not started, its shape depending on Phase 0's gate |
| 2. Android client: key lifecycle, restore hint, first-launch restore | Not started |
| 3. Device verification on stage (device-to-device and cloud) | Not started |
| 4. Production rollout and as-implemented docs | Not started |

## Context

### The requirement

Google Play's [technical quality requirements](https://support.google.com/googleplay/android-developer/answer/17492799?hl=en#zero-tap_sign-in_restoration): "From April 2027, apps that support user sign-in (optional or mandatory) must support Zero-Tap Sign-In restoration when a user moves from their previous Android device to a new one and selects to restore their data either from a device-to-device transfer or cloud backup." Compliance is "determined through successful restore key retrieval, resulting in the user being automatically signed in." Non-compliance "can affect an app's visibility and publishing capabilities." Games, enterprise device-management apps and "permanently private" apps are out of scope, and regulated apps (financial services, healthcare) may request an exemption. A self-hosted email client fits none of these.

The mechanism Google points to is the [Restore Credentials API](https://developer.android.com/identity/sign-in/restore-credentials). After sign-in, the app silently creates a **restore key**, a WebAuthn public-key credential that the server registers exactly as it would a passkey. The private half travels with the device backup: end-to-end encrypted in the cloud backup, or over the cable or wireless link in a device-to-device transfer. On the new device's first launch, the app retrieves the key, answers a server challenge with it, and the server starts a new session. Block Store, the older mechanism, counts only for integrations live in production by 2026-09-30, so it is closed to us.

### Where the Android client stands

The client signs in to Cognito's JSON API directly (`USER_PASSWORD_AUTH`, then a TOTP or SMS challenge; [docs/auth.md](../auth.md)). It keeps the session in `SharedPreferences` encrypted under an Android Keystore key (`KeystoreTokenStore`), which cannot survive a restore. The manifest sets `allowBackup="false"`, and `data_extraction_rules.xml` excludes every domain from both cloud backup and device-to-device transfer, including the control domain the user typed. A restored install therefore starts signed out and doesn't even know which server it belonged to.

Refresh tokens live 7 days on `cabal_admin_client`, so every session already ends within a week of its password-and-code sign-in.

### What already exists

- **Digital Asset Links.** Password AutoFill ([docs/password-autofill.md](../password-autofill.md)) publishes `https://admin.<control-domain>/.well-known/assetlinks.json` with the `delegate_permission/common.get_login_creds` relation for `com.cabalmail.android`. That is the relation Credential Manager checks for passkeys, and both stage and prod publish it today, naming the Play app-signing certificate (the repository-level `TF_VAR_ANDROID_SIGNING_CERT_FINGERPRINTS`).
- **The Apple client's posture.** The Apple Keychain items holding the session use `kSecAttrAccessibleAfterFirstUnlock`, not a `ThisDeviceOnly` class, so an iPhone's encrypted backup or direct transfer already carries a live Cabalmail session to the new device, bounded by the same 7-day refresh token. Zero-Tap gives Android the equivalent, with a credential that moves instead of the tokens themselves.

## Goals

- A user who moves to a new Android phone or tablet through a device-to-device transfer or a cloud restore opens Cabalmail signed in to the same account, on the same deployment, with no typing.
- The old device's posture does not weaken: nothing new is readable at rest, and sign-out still ends the device's ability to sign in.
- Each environment turns the feature on independently, after it is verified there.
- Anything that fails falls back to the normal sign-in screen, prefilled with the deployment and username.

## Non-goals

- **Passkeys as a user-facing sign-in method.** The backend built here could later carry them, but that is a separate decision.
- **Other clients.** The requirement is Google Play's. The Apple client already restores sessions (see above), and React, Linux and the browser extension are untouched.
- **Restoring app data.** The mail cache, preferences and per-install identifiers stay excluded. Only the small restore hint (see [The restore hint](#the-restore-hint)) is backed up.
- **Push notifications.** Google notes that notification registration does not restore. The existing opt-in push registration (`PushRegistrar`) already starts from the notifications setting, which stays per-install.

## Why not Cognito's built-in passkeys

Cognito supports WebAuthn passkeys on the Essentials and Plus plans through choice-based sign-in (`USER_AUTH`), which would make Cognito the relying party and spare us the verification code. But its MFA rules rule it out for this pool:

- With the pool's MFA set to optional and the default `SINGLE_FACTOR` passkey configuration, "users who have configured an MFA factor can only sign in with username-password authentication flows in choice-based sign-in." Stage and prod run `ENFORCE_USER_MFA=true`, so every human account past its 48-hour grace window has a TOTP or SMS factor, and every one of them would be refused.
- Under `MULTI_FACTOR_WITH_USER_VERIFICATION`, "passkey authentication with user verification satisfies MFA requirements." A restore key is created and used silently, with no biometric or PIN prompt, so it will most likely report no user verification. Phase 0 checks the actual flag. If restore keys do report user verification, revisit this section: the native route would remove most of Phase 1.

Two smaller reasons point the same way. Cognito's docs list `USER_PASSWORD_AUTH`, `USER_SRP_AUTH` and `CUSTOM_AUTH` as the flows threat protection evaluates, and `USER_AUTH` is not among them. And enabling `WEB_AUTHN` as an allowed first factor makes any registered credential a full sign-in on the pool's main client, where a dedicated client (below) keeps restored sessions separate and identifiable.

## Design

### The two flows

**On the old device (registration).** After a successful password-and-code sign-in, if the deployment offers restore sign-in and this install has no registered key:

1. `POST /restore_key_options` (Cognito-authorized, like every API call) returns WebAuthn creation options: a fresh challenge, `rp.id` = `admin.<control-domain>`, a random per-key `user.id` handle, `residentKey: "required"`, `attestation: "none"`, ES256.
2. The app calls `CredentialManager.createCredential` with a `CreateRestoreCredentialRequest` built from those options (`isCloudBackupEnabled` true; on `E2eeUnavailableException`, retry with false so device-to-device transfer still works).
3. `POST /restore_key_register` sends the registration response. The server verifies it and stores the public key.
4. The app records locally, in storage that is not backed up, that this install's key is registered, and which credential ID it is.

**On the new device (restore).** On first launch with no stored session and a restore hint present:

1. Fetch `config.json` from the hint's control domain. If it has no `restoreClientId`, stop and show the prefilled sign-in screen.
2. `InitiateAuth` with `AuthFlow: CUSTOM_AUTH`, the restore client's ID and `USERNAME` from the hint. The `CUSTOM_CHALLENGE` that comes back carries `CREDENTIAL_REQUEST_OPTIONS` (challenge, `rpId`, `allowCredentials` listing the user's restore keys).
3. `CredentialManager.getCredential` with a `GetRestoreCredentialOption` built from those options.
4. `RespondToAuthChallenge` with `ANSWER` set to the assertion JSON. Cognito returns tokens once the verify trigger accepts it.
5. Store the session, remembering it came from the restore client, then register a new restore key for this install (the registration flow above) so the next move works too.

Any failure on the way (no key, `NoCredentialException`, a refused assertion, a network error past retry) lands on the normal sign-in screen with the deployment and username prefilled.

### Relying party and origin

Each deployment is its own relying party, `admin.<control-domain>`, the host whose `assetlinks.json` already names the app. Using the admin host rather than the apex keeps the relying party on the one origin Cabalmail already controls for credentials. The app holds one restore key per install, for the deployment it is signed in to, which fits Google's "Restore Credentials supports only one account per app."

The server checks the `clientDataJSON` origin against `android:apk-key-hash:<base64url SHA-256 of the signing certificate>`, the form Google documents for native passkeys, computed from the same `TF_VAR_ANDROID_SIGNING_CERT_FINGERPRINTS` list that feeds `assetlinks.json`. One variable then governs both halves of the association. Phase 0 confirms that restore keys use this origin form.

### Backend components

- **`cabal-restore-keys` (DynamoDB).** Partition key `username`, sort key `credential_id`. Holds the COSE public key, the user handle, the signature counter, `created_at`, `last_used_at`, and a TTL. A TTL of 180 days, refreshed on use, reaps keys orphaned by uninstalls, since uninstalling deletes the device's half but nothing tells the server. Registration challenges live in the same table under a short TTL, keyed by challenge, bound to the username that requested them.
- **`restore_key_options`, `restore_key_register`, `restore_key_delete`.** API Gateway Lambdas behind the Cognito authorizer, one per endpoint as elsewhere in `lambda/api/`. Register verifies the response (challenge, origin, `rpIdHash`, the user-present flag, ES256 only, attestation `none`) and keeps at most 5 keys per user, evicting the oldest. Delete removes the caller's key by credential ID and is what sign-out calls.
- **Custom-auth triggers.** `define_auth_challenge`, `create_auth_challenge` and `verify_auth_challenge` in `lambda/counter/`, beside the existing pool triggers. Create looks up the user's keys, generates a challenge, and returns `CREDENTIAL_REQUEST_OPTIONS` publicly with the challenge kept private. Verify checks the assertion against the stored key (challenge, origin, `rpIdHash`, signature, the counter if it is non-zero) and updates `last_used_at` and the counter. Define issues tokens after one verified answer and fails the flow after one wrong one. These triggers are pool-wide, but only the restore client allows `CUSTOM_AUTH`, so nothing else can reach them.
- **`cabal_restore_client`.** A new app client with `ALLOW_CUSTOM_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH` only, no secret, token revocation on, and the same lifetimes as `cabal_admin_client`. A separate client means restored sessions carry their own `aud`, can be told apart in logs and by the [AMR plan](amr-mfa-assurance-plan.md), and can be shut off by removing one client without touching anyone's password sign-in.
- **Configuration.** `config.js` and `config.json` gain `cognitoConfig.restoreClientId`. It is empty unless a new Terraform variable `restore_sign_in` (default false) is true and `android_signing_cert_fingerprints` is non-empty. An empty value is the switch: the app neither creates keys nor attempts restores.
- **The verification library.** py_webauthn, which brings the native `cryptography` wheel, built on arm64 runners (decision D2 under [Decisions](#decisions)).

### Client components

#### Credential Manager

`androidx.credentials` and `credentials-play-services-auth` at the current stable line (1.6.0 at the time of writing; Restore Credentials needs 1.5.0 or later, Android 9 and Play services 24220000, all within the app's API 31 floor). Credential Manager lives in the app module behind a small interface, so the kit stays free of UI and Play-services dependencies. The kit owns the Cognito and API calls.

#### The restore hint

A restored install needs two values before it can ask anything: the control domain, and the username Cognito's challenge flow requires. A tiny dedicated `SharedPreferences` file, `restore_hint`, holds those two, and nothing else. The manifest moves to `allowBackup="true"`, and `data_extraction_rules.xml` switches from excluding everything to including only `restore_hint.xml` for both cloud backup and device transfer. An `<include>` list backs up only what it names, so the tokens, the per-install `clientId` and the mail cache stay where they are today. The hint is written at sign-in and cleared at sign-out. The values it holds are the same ones the sign-in screen prefills.

#### The session store

`KeystoreTokenStore` records which app client issued the session, because a refresh must go to the same client. Sessions from the restore client refresh through it until they expire, and the next sign-in is a normal password-and-code one through `cabal_admin_client`.

#### Lifecycle

| Event | Action |
|---|---|
| Password-and-code sign-in succeeds | Write the hint. If `restoreClientId` is set and no key is registered for this install, register one. |
| App start, signed in, no key registered | Register one. This covers users signed in when the feature ships. |
| First launch, no session, hint present | Attempt restore. |
| Restore succeeds | Register a key for this install. |
| Sign-out | `restore_key_delete` (best effort), `clearCredentialState(TYPE_CLEAR_RESTORE_CREDENTIAL)`, clear the hint and the registration record. |
| Refresh refused (`AuthExpired`) | Clear the local restore key and registration record, as Google advises for server-side invalidation. The next sign-in registers a new one. |

#### Challenges during restore

Threat protection runs in enforced mode on stage and prod, and a new device on a new network is what it scores as risky. If Cognito answers the custom challenge with an MFA challenge or a block, the app hands over to the existing sign-in UI: the code screen for an MFA challenge, the prefilled sign-in screen for a block. This is not zero-tap, but it is the right outcome for a sign-in Cognito considers risky. Phase 0 measures how often it happens.

### Security posture

**What a restore key proves.** Possession of the old device's backup. A cloud copy is end-to-end encrypted and decryptable only with the old device's screen lock. A device-to-device transfer needs the old device unlocked and physically present. The key is phishing-resistant: it signs only for the relying party it was made for, and only inside the app signed with the listed certificate.

**What it replaces.** On the new device, the restore key stands in for the password and the second factor. That is a real change for Android, and the same trade the Apple client already makes. The bounds:

- The session it starts lasts at most 7 days. After that, the user signs in with a password and code.
- Sign-out deletes the key on the server and on the device.
- An operator can revoke every restore key a user has (delete their rows), in addition to `admin-user-global-sign-out`.
- Admin actions can demand a password-and-code session once the [AMR plan](amr-mfa-assurance-plan.md) lands (see Interplay).

**The verification code is an authentication path.** A bug in the verify trigger is an authentication bypass for anyone who knows a username. Mitigations: a well-tested WebAuthn library rather than hand-rolled parsing (D2), the dedicated client, the feature off by default per environment, and a test suite with negative controls for every check (wrong challenge, origin, `rpIdHash` and signature; another user's credential; an unknown credential; a replayed answer; a missing user-present flag).

### Interplay

- **`require_admin_mfa`.** Unchanged. It runs on every token issue, custom auth included, and gates on MFA enrollment. A restoring user has a factor enrolled, so it passes, exactly as it does for their refreshes.
- **Threat protection.** Covers `CUSTOM_AUTH`. See [Challenges during restore](#challenges-during-restore).
- **The [AMR plan](amr-mfa-assurance-plan.md).** Restore-client tokens come from a sign-in that performed no MFA. Whatever `amr` Cognito assigns to a custom-auth sign-in (Phase 0 records it), the admin gate there should treat restore-client sessions as not MFA-verified, so admin actions need a normal sign-in. Matching on the restore client's `aud` is the fallback if `amr` doesn't distinguish them.
- **[docs/auth.md](../auth.md).** Gains the restore client, the custom-auth flow and the restore-key endpoints in Phase 4, as the contract every client reads.

## Phasing

### Phase 0: Spike

Settle what no documentation answers before committing to Phase 1's shape. Run it in the development environment, the warm spare kept for security-sensitive changes, plus a debuggable build on an emulator or device. Prerequisite: for debug builds, the debug keystore's fingerprint has to be in development's `assetlinks.json` (`TF_VAR_ANDROID_SIGNING_CERT_FINGERPRINTS` is currently a repository-level variable naming a single certificate, so this needs an environment-level override for development).

On the device, with creation options generated locally (no server needed):

- Capture a registration response: the `clientDataJSON` origin, the attestation format, the authenticator-data flags (user present, user verified, backup eligible, backup state) and the AAGUID.
- Whether creation succeeds with `userVerification` set to `"preferred"` and to `"discouraged"`, and whether it fails without a matching `assetlinks.json` entry.
- Whether a second `createCredential` replaces the key (a new credential ID) or fails.
- Whether `getCredential` honours `allowCredentials`, returns `userHandle`, and can be called twice with different challenges.
- Device-to-device and cloud restore through Android Studio's backup tooling, with `allowBackup` both true and false, and with `isCloudBackupEnabled` false.

In the development pool, with the triggers stubbed to accept any answer:

- Whether a pure `CUSTOM_AUTH` flow for a user with TOTP enrolled issues tokens without a `SOFTWARE_TOKEN_MFA` challenge. Cognito's docs describe the automatic MFA step only after a `PASSWORD_VERIFIER` challenge.
- What threat protection does to a custom-auth sign-in from a new device, in audit and in enforced mode.
- The `amr` and `acr` claims on the resulting tokens, if the claim rollout (from 2026-11-04) has reached the pool.

**Gate.** If restore keys report user verification, try Cognito's native passkeys under `MULTI_FACTOR_WITH_USER_VERIFICATION` before building the custom path. Otherwise build Phase 1 as designed. Record the findings in this plan.

**Status:** Not started.

### Phase 1: Backend (inert)

First, move `app.yml`'s `lambda-api` and `lambda-counter` jobs to `ubuntu-24.04-arm` (D2), and make `build-api-one.sh` fail when an x86_64 function's zip contains a compiled extension. This can ship on its own, ahead of everything else.

Then the table, the three API Lambdas, the three custom-auth triggers, the restore client and the `restore_sign_in` variable, with `restoreClientId` empty everywhere until Phase 3. Unit tests for every verification check and its negative control. Apply to development, then stage with the variable still false. The per-account CI Terraform policy is managed by hand, so check it covers anything new (Cognito trigger wiring, the table) before the first apply.

**Status:** arm64 build runners and the `fetch_bimi` guard done (#2309, deployed to stage 2026-11-02). The first stage run built on `ubuntu-24.04-arm`, and 69 of 76 functions matched their deployed zips byte for byte (the other two aren't deployed on stage). The remaining five (`push_dispatch`, `fetch_bimi`, `rss_fetch`, `rss_subscribe`, `rss_opml_import`) redeployed once. Diffing their old and new zips showed every module, and `fetch_bimi`'s resvg binary, identical. The only change was the shebang of pip's unused `bin/` console-script launchers (from `rsa` and `publicsuffixlist`), which names the build interpreter's path and changed from `x64` to `arm64`, and those launchers' `RECORD` lines. The rest of Phase 1 is not started.

### Phase 2: Android client

Credential Manager behind its interface, the restore hint and the new backup rules, the session store's client field, the lifecycle table, the first-launch restore path and its fallbacks. Kit tests for the Cognito custom-auth exchange and the registration calls against a mock transport. App tests for the lifecycle decisions. This needs an `Android:` changelog fragment, since it ships to users.

**Status:** Not started.

### Phase 3: Device verification on stage

Set `restore_sign_in` on stage and verify on real hardware: a device-to-device transfer, and a cloud restore, each between two physical devices running Android 12 or later (the app's floor; Restore Credentials itself reaches back to Android 9). Also check the fallbacks (a hint with no key, a revoked key, a session that expired before the move) and what threat protection does in practice. Android test devices are shared, so schedule them.

**Status:** Not started.

### Phase 4: Production and documentation

Enable on prod. Fold the contract into [docs/auth.md](../auth.md) and write the operator view (enabling it, revoking a user's keys) as top-level documentation. Update the AMR plan's admin gate per Interplay if it has not already landed.

**Status:** Not started.

## Open questions

- **Step-up after a cloud restore (Google).** Google's FAQ says the app "must decide whether to require an additional step-up verification" and that "Restoring the user's identity context is sufficient to meet the requirement," yet compliance is judged by the user "being automatically signed in." Whether asking for the TOTP code after a cloud restore still counts is the pending answer that matters. The weekly watch on #2306 tracks it.
- **Enforcement details (Google).** How compliance is checked, whether apps only on testing tracks are checked, and the exact date in April 2027.

## Decisions

Recorded 2026-11-01.

- **D1: The restore key signs in on its own,** after device-to-device transfers and cloud restores alike. This matches the Apple client and Google's expectation for device-to-device transfers. The alternative, demanding the TOTP code after every restore, would have kept Android's factor posture unchanged, but risked non-compliance and may not have been possible at all: a custom-auth flow can't verify Cognito's TOTP itself. If Google's pending answer requires a step-up after cloud restores, revisit this.
- **D2: The verifier uses py_webauthn, built on arm64 runners.** The Lambdas run on arm64, but `app.yml`'s `lambda-api` and `lambda-counter` jobs build them on x86_64 `ubuntu-latest`, which is why `push_dispatch` kept its ES256 signing pure Python (`ecdsa`; see its `requirements.txt`). The well-tested WebAuthn library (`webauthn`, py_webauthn) needs the native `cryptography` wheel, so both jobs move to the `ubuntu-24.04-arm` runners the docker job already uses. Hand-rolling the narrow ES256, attestation-`none` subset was the alternative, rejected because hand-written WebAuthn parsing is where verification bugs live. The move is safe today: every Lambda's pip closure is pure Python, and `fetch-resvg.sh` fetches `fetch_bimi`'s binary for an explicit `linux-x86_64` target rather than the runner's. It inverts one risk, though. `fetch_bimi`, the lone x86_64 function, would get arm64 builds of any native dependency it gained, so the build fails if an x86_64 function's zip contains a compiled extension (see Phase 1).
- **Key retention: unused keys expire after 180 days, and each user keeps at most 5,** the oldest evicted first.

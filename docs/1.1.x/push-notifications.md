# Push Notifications Plan

## Context

Cabalmail's iOS app ([apple/Cabalmail](../../apple/Cabalmail)) currently learns about new mail only while running in the foreground, via the IMAP IDLE loop in [apple/CabalmailKit/Sources/CabalmailKit/IMAP/LiveImapClient+Idle.swift](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/LiveImapClient+Idle.swift). When the app is suspended or terminated, iOS does not keep the IMAP connection alive, so the user gets no signal that mail has arrived until they reopen the app. This is the largest remaining UX gap before 1.0 and the most common piece of feedback from native-app users.

This plan introduces server-originated push notifications via the Apple Push Notification service (APNs) with three constraints:

1. **Apple's infrastructure must not see notification content.** Subject, sender, and snippet are visible to the user but not to APNs. This rules out putting message details in the APNs payload directly.
2. **The wake-signal path must not couple the IMAP container to AWS Lambda.** Inbound delivery already runs through Sendmail and Procmail in the `imap` container; push enqueueing is a side-effect of delivery and should be decoupled from APNs send latency or failure.
3. **In-notification actions must be supported.** `Open`, `Mark as Read`, and `Archive` need to work without launching the full app for the latter two.

The design also targets the macOS app ([apple/CabalmailMac](../../apple/CabalmailMac)) with the same APNs path; macOS-specific notes are called out where they diverge.

## Goals

- New mail produces a system notification on iOS (and macOS) within ~5 seconds of delivery to the IMAP store.
- Notification body shows sender + subject + snippet, but only after on-device enrichment. The APNs payload itself contains no message content.
- `Open` opens the message in the app; `Mark as Read` and `Archive` complete in the background without launching the app.
- Per-account and per-folder opt-out (a user with five Cabalmail addresses can mute four of them).
- Token registration is reversible and per-device; logging out or uninstalling stops notifications without operator intervention.
- The push send path is asynchronous to delivery: a slow APNs send does not slow inbound mail.

## Non-goals

- End-to-end encrypted notification payload (Pattern B from the design discussion). Cabalmail's backend already has plaintext IMAP access; encrypting in-payload buys nothing against the threat model and adds significant key-management complexity. We use Pattern A (wake-signal + on-device fetch) instead.
- Android push (FCM). Android client is on the 1.1.x roadmap and will get its own plan.
- Web push for the React admin app. Browser push has a different API surface and a different consent flow; it is out of scope here.
- Replacing IDLE in the foreground app. APNs supplements IDLE; it does not replace it. While the app is open, IDLE remains the source of truth for instant updates.
- Per-message rule-based push (e.g. "only push if from VIP"). Filtering is folder-level only in 1.0.x; per-sender rules can layer on top later under the procmail-rules roadmap item (1.3.x).
- Push for SMTP-OUT bounce notifications, DMARC reports, or other system-generated mail to `mail-admin.<domain>`. The admin mailbox is operator-facing, not user-facing.

## Architecture

### Component diagram

```
                                                        +------------------------+
                                                        |  iOS / macOS app       |
                                                        |  +------------------+  |
   +-------------+        +--------------------+        |  | Notification     |  |
   | Inbound MX  |        | imap container     |        |  | Service          |  |
   | (smtp-in)   |  --->  | sendmail+procmail  |  -+    |  | Extension (NSE)  |  |
   +-------------+        +--------------------+   |    |  +--------+---------+  |
                                                   |    |           | enrich     |
                                                   v    |           v            |
                                          +-----------+ |  +-----------------+   |
                                          |  push SQS | |  | main app        |   |
                                          +-----+-----+ |  | (action handler)|   |
                                                |       |  +-----------------+   |
                                                v       +------------+-----------+
                                          +-----------+              ^
                                          |  push     |              |
                                          |  Lambda   |  --APNs-->   | OS
                                          +-----+-----+              |
                                                |                    |
                                                v                    |
                                          +-----------+               |
                                          | DynamoDB  |               |
                                          | tokens    |               |
                                          +-----------+              ----- Apple APNs edge
```

### Message flow

1. Mail arrives via the `smtp-in` tier and is relayed to the user's mailstore on the `imap` tier.
2. The `imap` container's Procmail recipe fires after each successful delivery and enqueues a JSON message to an SQS queue (`cabal-push-queue`) containing `{user, folder, uid, msg_id}`. Local delivery is not blocked on the enqueue: if SQS is unreachable the message goes to a local fallback file and is drained on the next reconcile loop.
3. A push Lambda (`push-dispatch`) consumes the queue, looks up active device tokens for the user in DynamoDB (`cabal-push-tokens`), and sends one APNs HTTP/2 request per token.
4. The APNs payload is a wake signal only: `{"aps": {"alert": "New mail", "mutable-content": 1, "category": "MAIL_MESSAGE", "sound": "default"}, "msgRef": {"folder": "INBOX", "uid": 4271}}`.
5. On the device, the Notification Service Extension wakes, calls a thin enrichment endpoint (`/push/envelope`) with the user's existing Cognito JWT, and replaces the alert text with `From <sender> | <subject> | <snippet>`.
6. The OS displays the enriched notification. If the NSE times out or the network is unreachable, the OS displays the fallback `"New mail"`.
7. If the user taps `Open`, the main app launches and routes to the message via `msgRef`. If the user taps `Mark as Read` or `Archive`, the OS wakes the main app in the background (~30s budget); the action handler refreshes the Cognito token if needed and uses the existing `LiveImapClient` to perform the IMAP operation.

### Why a fetch-on-wake enrichment endpoint instead of reusing CabalmailKit's IMAP client

The NSE could in principle link `CabalmailKit` and call `LiveImapClient` directly to fetch the envelope. This was considered and rejected for 1.0.x:

- An NSE process is fresh per notification. Cached IMAP connections from the main app are not reachable from the NSE process.
- A cold IMAP fetch is TLS handshake + LOGIN + SELECT + UID FETCH, which is 4-5 round trips. At typical mobile latency that is 600-1500 ms. APNs gives the NSE roughly 10-15 seconds of usable wall time, so it would work, but the p95 is uncomfortably close to the budget.
- HTTPS to API Gateway is one round trip with HTTP/2 connection reuse possible across notifications via the system network stack, typically 100-300 ms.
- The enrichment endpoint is small enough to add in one Lambda; it does not justify a backend redesign.

We can revisit this if a future feature (e.g. fully offline notification rendering) makes IMAP-from-NSE more attractive.

### Why a separate SQS queue instead of synchronous Lambda invocation from Procmail

- Procmail runs inside the `imap` container, in the delivery hot path. A direct Lambda invocation would mean every inbound message pays APNs send latency before delivery completes.
- SQS gives natural batching, retries, and a dead-letter destination without writing custom retry logic in shell.
- The push Lambda can be scaled independently of mail delivery throughput, and a stuck APNs key cannot back-pressure inbound mail.
- The queue is the natural integration point with the existing reconfiguration SNS/SQS pattern in [terraform/infra/modules/ecs](../../terraform/infra/modules/ecs).

## Backend components

### New DynamoDB table: `cabal-push-tokens`

| Attribute | Type | Notes |
|---|---|---|
| `user` (PK) | S | Cognito username, same value used in [cabal-addresses](../../terraform/infra/modules/table) |
| `device_token` (SK) | S | APNs device token, hex-encoded, 64 bytes |
| `bundle_id` | S | `com.cabalmail.app` or `com.cabalmail.mac`. Determines which APNs topic to use. |
| `platform` | S | `ios` or `macos`. Informational; bundle_id is authoritative. |
| `app_version` | S | For diagnostics. |
| `locale` | S | For future localized fallback strings. |
| `enabled_folders` | SS | Folder names to push for. Empty set = inbox only. Special value `*` = all. |
| `created_at` | S | ISO 8601. |
| `last_seen_at` | S | Updated on each successful push or token re-registration. Used to GC stale tokens. |
| `last_failure` | S | Optional; set to APNs failure reason on rejection (e.g. `BadDeviceToken`). |

Tokens are encrypted at rest with the existing customer-managed KMS key. The table is in the existing backup plan.

### New Lambda functions

| Function | Trigger | Purpose |
|---|---|---|
| `push_register` | API Gateway POST `/push/register` | iOS app calls on first launch and on token rotation. Upserts the token row, scoped to the authenticated Cognito user. |
| `push_deregister` | API Gateway POST `/push/deregister` | iOS app calls on logout or when the user disables notifications. |
| `push_envelope` | API Gateway POST `/push/envelope` | Called by the NSE. Body: `{folder, uid}`. Returns `{from, subject, snippet}` only. Reuses `get_imap_client` from [helper.py](../../lambda/api/_shared/helper.py). Subject and snippet are truncated to safe display lengths server-side. |
| `push_dispatch` | SQS event source | Consumes `cabal-push-queue`. Per message: looks up tokens for the user, filters by `enabled_folders`, sends APNs requests in parallel, updates `last_seen_at` / `last_failure`, and deletes tokens on `Unregistered (410)` or `BadDeviceToken`. |

`push_dispatch` reads the APNs `.p8` key and team/key/bundle IDs from SSM SecureString parameters under `/cabal/apns/`. JWT generation will bundle `cryptography` (already a transitive dep) per-function for ES256 signing, the same way other API functions bundle their Python deps.

### Procmail recipe change

Add to [docker/imap/configs/procmailrc](../../docker/imap/configs/procmailrc):

```
:0c
| /usr/local/bin/push-enqueue.sh "$LOGNAME" "INBOX" "$Subject"
```

The `:0c` recipe runs as a side effect (carbon copy: delivery still continues unconditionally). The script is best-effort: it pipes a single JSON line to `aws sqs send-message` and exits zero regardless of result. Failures land in `~/.procmail/push-enqueue.log` for diagnosis but do not affect mail flow. The script lives in [docker/shared/push-enqueue.sh](../../docker/shared/push-enqueue.sh) so it can be reused across delivery paths if needed.

The UID is not known at procmail time. We pass `LAST_UID_HINT` via Dovecot's last-uid lookup in the script, falling back to "look up newest in folder" on the consumer side if the hint is stale. This keeps the recipe trivial and avoids a Dovecot LDA hook.

### SQS queue and IAM

`cabal-push-queue` is added to [terraform/infra/modules/ecs](../../terraform/infra/modules/ecs) (or a new `push` module if it grows). The `imap` task role gets `sqs:SendMessage` on this queue only. The `push_dispatch` Lambda execution role gets `sqs:ReceiveMessage` / `DeleteMessage` and `dynamodb:GetItem` / `Query` / `UpdateItem` on `cabal-push-tokens`.

A dead-letter queue catches messages that fail dispatch repeatedly; it is monitored via the existing alerting stack (see [docs/monitoring.md](../monitoring.md)).

## Client components

### iOS app changes (apple/Cabalmail)

- Add a Notification Service Extension target. Bundle ID: `com.cabalmail.app.NotificationService`. Embed in the main app.
- Add an App Group entitlement (`group.com.cabalmail.app`) to both the app and the NSE so the Cognito JWT, refresh token, and `api_url` can be shared via Keychain Access Group + `UserDefaults(suiteName:)`.
- On app launch (after sign-in), call `UNUserNotificationCenter.requestAuthorization`, register for remote notifications, and POST the resulting token to `/push/register`.
- Register notification categories at launch:

  ```swift
  UNUserNotificationCenter.current().setNotificationCategories([
      UNNotificationCategory(
          identifier: "MAIL_MESSAGE",
          actions: [
              UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground]),
              UNNotificationAction(identifier: "MARK_READ", title: "Mark as Read", options: []),
              UNNotificationAction(identifier: "ARCHIVE", title: "Archive", options: []),
          ],
          intentIdentifiers: [],
          options: []
      )
  ])
  ```

- Implement `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` to dispatch on `actionIdentifier`. `MARK_READ` and `ARCHIVE` use the existing `LiveImapClient.setFlags` and `LiveImapClient.move` methods. The completion handler is called only after the IMAP operation resolves; a `beginBackgroundTask` wraps the work to extend the budget if needed.
- Cognito token refresh: the action handler checks token expiry and uses the refresh token (also in the App Group Keychain) to mint a fresh JWT before any IMAP or HTTP call.

### NSE implementation (apple/Cabalmail/NotificationService)

A new minimal target with **no third-party dependencies**. Pulls only `Foundation` and `UserNotifications`. The body:

1. Read `msgRef` from `request.content.userInfo`.
2. Read `api_url` and access token from the App Group container.
3. Synchronously (within the NSE async context) `URLSession.data(from:)` against `/push/envelope` with a 10-second timeout.
4. On success: replace `bestAttemptContent.title` with the sender, `bestAttemptContent.body` with `subject + "\n" + snippet`, and call the completion handler.
5. On failure (timeout, network error, non-2xx, decode error): call the completion handler with the original content. The fallback `"New mail"` ships.

### Archive folder discovery

The current Dovecot mailbox config in [docker/imap/configs/dovecot/15-mailboxes.conf](../../docker/imap/configs/dovecot/15-mailboxes.conf) defines `Drafts`, `Junk`, `Trash`, `Sent` but **no** `Archive`. We add:

```
mailbox Archive {
  auto = subscribe
  special_use = \Archive
}
```

The iOS app discovers the archive folder via IMAP `LIST (SPECIAL-USE) "" "*"` and caches the result in `UserDefaults`. If the user has renamed or hidden the folder, settings expose a folder picker. The cached folder name is what the `ARCHIVE` action uses.

### Foreground behavior

When the app is in the foreground, `UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)` is called with the incoming notification. We suppress the banner (the IDLE-driven UI already shows the new message) and just play a subtle sound. This avoids double-notifying.

## Privacy posture

What APNs sees per push:

- Source IP of the dispatching Lambda (an AWS NAT egress IP, shared across the VPC).
- The opaque device token (already known to APNs).
- Topic = bundle ID (`com.cabalmail.app`).
- Payload `{"aps": {"alert": "New mail", ...}, "msgRef": {"folder": "INBOX", "uid": 4271}}`. The `uid` is an integer that, on its own, does not identify the sender, subject, or content.
- Timestamp.

What APNs does **not** see: sender address, recipient address, subject, body, attachments, or any cleartext message metadata.

What the lock screen shows when previews are disabled:

- App name and `"New mail"`. The NSE result is cached and revealed when the user authenticates.

What the device sends to our backend at notification time:

- One HTTPS request to `/push/envelope` with the user's JWT and `{folder, uid}`. This is no more than the main app already sends during normal IMAP polling.

The APNs `.p8` key is high-value: a leak lets an attacker send arbitrary notifications to every Cabalmail device. Mitigations: stored in SSM SecureString with KMS encryption, IAM-restricted to the `push_dispatch` Lambda role only, rotatable via App Store Connect (issue new key, update SSM, revoke old after deploy). A scheduled rotation is added to the operations runbook in [docs/operations.md](../operations.md).

## Phasing

Each phase is independently deployable and reversible. Phases 1-2 ship infrastructure with no user-visible change; phase 3 turns on the user-visible feature.

### Phase 1: Token registration plumbing

- Create `cabal-push-tokens` DynamoDB table (Terraform).
- Provision APNs `.p8` key in App Store Connect; store in SSM under `/cabal/apns/`.
- Build `push_register` and `push_deregister` Lambdas.
- iOS app: request notification permission on first launch after sign-in; register/deregister tokens. **No notifications are sent yet.**
- Verify in DynamoDB that real devices register on every launch and after token rotation.

### Phase 2: Server-side dispatch

- Create `cabal-push-queue` SQS queue + DLQ (Terraform).
- Build `push_dispatch` Lambda with SQS event source.
- Add `push-enqueue.sh` to `docker/shared/`; wire into `procmailrc`.
- Send wake-signal-only payload (no NSE yet). Devices receive bare `"New mail"` notifications.
- Validate end-to-end latency from delivery to OS notification.

### Phase 3: Enrichment

- Build `push_envelope` Lambda.
- Add NSE target to the iOS app; embed and ship.
- Verify enriched notifications display correctly with previews on, and degrade gracefully to `"New mail"` with previews off or NSE failure.

### Phase 4: Categories and actions

- Register `MAIL_MESSAGE` category with three actions in the iOS app.
- Add `category: "MAIL_MESSAGE"` to dispatched payloads.
- Implement action handlers using `LiveImapClient`.
- Add `Archive` mailbox to Dovecot config; backfill auto-create for existing users via a one-shot `reconfigure.sh` step.

### Phase 5: Per-folder opt-out and preferences

- Extend `push_register` to accept `enabled_folders`.
- Add a Notifications settings screen to the iOS app: master toggle, per-account toggle, per-folder picker.
- Mirror state to the existing user preferences mechanism in [lambda/api/get_preferences](../../lambda/api/get_preferences) / [set_preferences](../../lambda/api/set_preferences) for cross-device consistency.

### Phase 6: macOS parity

- Add NSE target to the macOS app.
- Reuse the same `/push/envelope` endpoint and the same `push_dispatch` Lambda.
- Distinct bundle ID and APNs topic; the dispatch Lambda already keys topic off `bundle_id` per-token.

## Operational concerns

### Quiesce

Quiesced environments (see [docs/quiesce.md](../quiesce.md)) scale ECS services and the NAT instance to zero. The push path degrades cleanly:

- The `imap` container is down, so no mail is delivered, so `push-enqueue.sh` is never invoked.
- If a residual SQS message exists from before quiesce, `push_dispatch` will fail to reach API Gateway from outside the VPC (no NAT). The DLQ catches it; manual replay after un-quiesce is fine.
- The dispatch Lambda is **not** scaled down by quiesce because Lambda has no minimum cost when idle. Leaving it provisioned is harmless.

### Multi-device collapse

Two devices for the same user receive two notifications. We use APNs `apns-collapse-id` set to `msgRef.folder + ":" + msgRef.uid` so a re-send (e.g. retry from DLQ) does not double-notify. Cross-device collapse is **not** done; each device shows its own notification. This matches user expectation (the notification is dismissed independently when the user opens the message on one device).

### Read-state propagation

`Mark as Read` from the lock screen sets `\Seen` via IMAP. Other devices see the change on their next IDLE event or poll. Inversely, marking-read on the web client does not actively dismiss the iOS notification: this is a known minor inconsistency we accept in 1.0.x. A future enhancement could push a "dismiss" notification with `apns-collapse-id` matching the original, but it adds APNs traffic for limited gain.

### Token cleanup

`push_dispatch` deletes tokens on:

- HTTP 410 `Unregistered` from APNs (app uninstalled or token invalidated).
- HTTP 400 `BadDeviceToken`.

A scheduled Lambda runs weekly to GC tokens with `last_seen_at` older than 90 days as a backstop.

### Monitoring

Add CloudWatch metrics published by `push_dispatch`:

- `cabal.push.sent` (counter, dimensioned by bundle_id).
- `cabal.push.failed` (counter, dimensioned by reason).
- `cabal.push.latency_ms` (histogram, queue receive to APNs response).

Alerts in [terraform/infra/modules/ecs](../../terraform/infra/modules/ecs) monitoring stanza:

- DLQ depth > 0 for 15 minutes.
- `push.failed` rate > 5% over 5 minutes.

## Open questions

- **Snippet length.** APNs supports up to 4 KB total payload; we use almost none of it. The enrichment endpoint can return up to ~3 KB of snippet without trouble. Picking the right truncation length (notification preview area is small; iOS truncates aggressively anyway) is a UX decision deferred to phase 3 implementation.
- **HTML-only mail snippets.** Stripping HTML for the snippet is non-trivial. First pass: `bs4.get_text()` with whitespace normalization, truncated to 240 chars. If the result is empty or garbled, fall back to a generic snippet.
- **Cognito token expiry in the NSE.** The NSE has no UI to prompt re-auth. If the access token has expired, the NSE has two choices: refresh in-extension (adds a round trip and complexity), or fail to enrich and fall back to `"New mail"`. Phase 3 ships with fall-back behavior; we revisit if it fires often in practice.
- **macOS Focus / Do Not Disturb behavior.** Worth verifying that the macOS app respects system-wide focus modes the same way iOS does. Expected to be free, but call it out in the test plan.

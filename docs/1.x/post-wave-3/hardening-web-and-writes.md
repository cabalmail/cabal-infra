# Hardening: reader web content and write paths

> **Repo copy (2026-10-15):** Written in the 2026-10 Cabalmail Client Architecture project, which has closed. This copy is self-contained: what it took from that project's audits, scope docs, soak notes and threads is stated where it is used. Names, machines and test accounts are generalized for publication. Repo line numbers are as of the commit named under "Written"; re-check them before starting.

**Recommendation:** Session, run as two sequential sessions. Session A (PRs 1, 2, 6, 3) closes three holes (the composer, the feed reader's #1911 and `/new`), needs private handling and wants a quick promote; Session B (PRs 4, 5) fixes write replays in Kit files other plans also want and can wait a release. Neither needs parallel threads, a migration or an outside event, and each has one batch of decisions.
**Size:** M in all. Session A about M (three Apple PRs and one Lambda PR); Session B about S to M (two Kit PRs).
**Priority:** Session A: Now. The feed reader runs script that arrives in third-party content in shipped builds (#1911, reproduced), and the composer (C1, found while writing this plan, not yet reproduced) and `/new` (W4, by code reading) have holes whose detail this copy withholds. Session B: Next. Nothing a user would notice is being lost today, and its files are busy.
**Depends on:** nothing hard. Order only: release PR #2043 merges before any PR here lands on stage (met: it merged on 2026-10-12); no Kit PR here (1, 4, 5) is open during kit-split.md's Kit freeze; Session B goes before or after test-debt.md's A4 and A5, never beside them. Soft: docs-and-bookkeeping.md's PR 1 writes the API change rule into the repo for PR 6 to cite.
**Unblocks:** android-parity.md (its PR 1 mirrors decisions 2 and 3 and ships in PR 2's release); sqlite-mail-store.md (order only: PR 4's replay table feeds its decision 9); kit-split.md (soft: its PR E waits for PR 5's change at `CabalmailClient.swift:228`).
**Duo groundwork:** None. These web views and write paths behave the same on either Duo display. (duo-support.md's hotspot table guesses this plan edits `MessageDetailView*.swift`; it edits `HTMLBodyView*.swift` and `ArticleWebView.swift` instead.)
**Written:** 2026-10-12 against stage 50e6022; re-check line numbers before starting.

> **Withheld (2026-10-15):** The Recommendation and Priority lines described the mechanism of C1 (the composer) and W4 (`/new`). Under decision 1 that stays out of public forums until the fixes are on prod for every client (for Apple, the App Store build people install), which is not yet confirmed, so this public copy withholds it. Both fixes shipped in release 1.31.2.

> Handling note: C1 (the composer) and W4 (`/new`) below are unfixed holes. This plan lives in project files. Keep their mechanism out of any issue, PR, commit message or changelog until the fix is on prod (decision 1). #1911 is already public.

> **Erratum (2026-10-15):** Both fixes have merged: PR 1 as #2053 and PR 6 as #2054, released in 1.31.2 (PR #2055, dated 2026-10-14). This copy of the plan is in the public repository, not in project files, so it withholds C1's and W4's mechanism wherever the plan described it (each place carries a **Withheld** note). The handling note still applies until decision 1's condition is confirmed.

Labels: C1 is PR 1, C2 (#1911) is PR 2, C3 is PR 3, W1 is PR 4, W2 and W3 are PR 5, W4 is PR 6. The numbers stay fixed because sibling plans cite them. Session A runs PRs 1, 2, 6, 3 in that order; Session B runs 4, then 5.

> **Added (2026-10-17):** W5 is PR 7 (the browser extension and a refused address create) and W6 is PR 8 (the admin create-address route, after decision 8). Both belong to Session B and run beside PRs 4 and 5, since neither touches a Kit file.

## Progress

This table and the **Status:** line under each work item are updated in the same PR as the work, so the next session reads where things stand instead of reconstructing it.

| Work item | Status |
| --- | --- |
| Session A, before PR 1: reproduce C1 on the Mini | Not recorded; PR 1 has since merged and shipped |
| Session A, PR 1: composer (C1) | Done: #2053 (`5eb7284`), released in 1.31.2 |
| Session A, PR 2: #1911, feed reader mode runs no script (C2) | Done: #2056 (`5046716`), released in 1.31.3 (2026-10-17); stage check passed (the Mini's reader check and the maintainer's iPhone check of the stage TestFlight build) and #1911 closed on 2026-10-17 |
| Session A, PR 6: `/new` and an existing address (W4) | Done: #2054 (`c467789`), released in 1.31.2; stage proof passed on 2026-10-17 |
| Session A, PR 3: bridges in their own world, a lint rule, the rule written down (C3) | Done: #2057 (`f078467`), released in 1.31.3 (2026-10-17) |
| Session B, before PR 4: check the replay premise on stage | Not started |
| Session B, PR 4: the transport retries only replay-safe requests (W1) | Not started |
| Session B, PR 5: no re-send after delivery, no silent outbox or draft failures (W2, W3) | Not started |
| Session B, PR 7: the browser extension and a refused address create (W5) | Not started (added 2026-10-17) |
| Session B, PR 8: the admin create-address route and an existing address (W6) | In review (2026-10-17); decision 8 answered: add the handling |
| Decisions | 1, 2, 3, 6, 7 and 8 answered; 4 (Session B) open; 5 a recorded decline |

## Decisions for the maintainer

Session A asks 1, 2, 3, 6 and 7; Session B asks 4 and, since 2026-10-17, 8. Decision 5 is a recorded decline.

1. **C1 and W4: public issue now, or private until fixed?** **Private (recommended):** each is reproduced privately, fixed under a neutral PR title, and filed publicly once the fix is on prod. Consequence: no issue describes an open hole, though the fix's diff and tests are public from the branch's first push, so the session tests PR 1 on the Mini before pushing and asks for a promote as soon as it soaks. Public now: the recipe is public for the whole fix cycle. Default: private.
   - **Answered 2026-10-13: private.** The maintainer: keep it "out of public forums until implemented". Session A is next.
2. **#1911: fix the feed article's web view, or render reader mode in a separate one?** **Same view (recommended),** with two independent locks. Consequence: images, links, the per-feed storage and toggling back keep working as today. Separate view: a second web view kept in step with the first; toggling swaps views, so history and scroll do not carry across (inferred), and it is more code. Default: same view.
   - **Answered 2026-10-15: same view.** Session A recorded it, taken on the recommended answer; PR 2 (#2056) merged on it.
3. **Video players in feed reader mode: Drop or Keep?** **Drop (recommended).** Consequence: YouTube and Vimeo players show only on the publisher's page, one tap away, and reader mode runs no third-party code. Keep: players stay, which means allowing their frames (whether they still play with the reader's script off is untested). Default: drop.
   - **Answered 2026-10-15: drop video players.** Session A recorded it, taken on the recommended answer; PR 2 (#2056) merged on it.
4. **(Session B) After a dropped connection, which requests may be retried once: per endpoint, or by HTTP method?** **Per endpoint (recommended).** Consequence: archive, move, flag, delete, send and sign-in keep their quiet retry; creating a folder, saving rules and the sign-up and password-reset steps stop replaying into a misleading error. By method, read as HTTP defines it (GET, PUT and DELETE retry, POST does not), keeps the misleading New Folder and Save Rules replays (both PUT) and drops the harmless sign-in, push and feed-state retries (all POST). Read as GET-only, which the audits seem to have meant (they took `/send` and `/move_messages` for POSTs), it takes the retry from archive, flag and send, so a dropped connection while archiving shows an error and undoes a move that happened. Default: per endpoint.
5. **#1804's server remainder (omit `message_raw` on a signing failure; 404 from `fetch_inline_image` when no part matches): Ship or Decline?** **Decline (recommended).** Consequence: nothing changes for users. Apple and Android cope with the "Error" sentinel; React's View Source would request a relative "Error" URL and fail, and its inline image would be broken. Both are rare, because presigning is local. A new 404 would collide with the existing "That message is no longer in X" 404. Default: decline, recorded here. No answer was found in the rearchitecture project's scope docs, and its top-level chat was not checked.
6. **W4: make `/new` refuse an address that already exists?** **Yes (recommended).** It adds a 409 to an existing endpoint, your call under the additive API rule, and the stage proof needs the two stage test accounts (test account 1 and test account 2) granted one shared stage domain (an admin action), cleaned up after. Consequence: creating an address that is already in use is refused with a plain sentence. No: W4 stays open. Default: a unit test proves it against a stubbed table, the fix opens as a draft, and nothing touches stage or merges until you answer.
   - **Answered 2026-10-15: yes.** Session A recorded it, taken on the recommended answer; PR 6 (#2054) merged on it and shipped in 1.31.2. The stage proof has not run: it waits on the maintainer running a proof script on the Mini as test accounts 2 and 3.

   > **Erratum (2026-10-16):** No domain grant was needed for test accounts 1 and 2: they already share stage domains (the maintainer, 2026-10-15). But the rig's credential helper serves test accounts 2 and 3, not 1, so on 2026-10-15 the hardening session wrote a proof script for the maintainer to run on the Mini as test accounts 2 and 3, through the API only. It stops before writing anything if those two share no stage domain; granting test account 3 one of test account 2's stage domains would then unblock it. The script and its report stay with the closed project; see "Session A remainder" under "How to start it".

   > **Erratum (2026-10-17):** The stage proof has run and passed: the maintainer ran the script on the Mini on 2026-10-17 as the two stage test accounts, which share a stage domain, so no grant was needed. See PR 6's **Status:**.

7. **Remote images in a quoted message: Block or Allow?** **Block (recommended).** Consequence: tapping Reply or Forward never fetches anything from the original sender's servers. Pasted images and reopened drafts are untouched. Allow: today's behaviour. Default: block.
   - **Answered 2026-10-15: block remote images in quoted messages.** Session A recorded it, taken on the recommended answer; PR 1 (#2053) merged on it and shipped in 1.31.2.
8. **(Session B, added 2026-10-17) The admin create-address route (W6): give it the handling of an existing address that `/new` has had since 1.31.2, leave it, or remove it?** **Add the handling (recommended).** Consequence: an admin create for an address that is already in use is refused with a plain sentence, and new addresses are created in lower case, as with `/new`; an admin who wants to change an existing address's users uses Assign. Leave: no change. Remove: the route, its function and the web app's unused client call go away, and anything else that calls the route breaks. Default: add the handling.
   - **Answered 2026-10-17: add the handling.** The maintainer chose the recommended answer; PR 8 carries it in Session B.

> **Withheld (2026-10-15):** The consequence clauses of decisions 6 and 7 described the effects of W4 and of C1's remote-image path. That detail is withheld from this public copy under decision 1 (out of public forums until the fixes are on prod for every client, not yet confirmed). Both fixes shipped in 1.31.2.

## What you'll see change

- **PR 1 (composer):** Reply and Forward look the same. The composer keeps only the formatting of a quoted, pasted or dropped message, and quoting a message no longer fetches remote images (decision 7).
- **PR 2 (#1911):** feed reader mode looks the same, minus video players (decision 3). Script in an article no longer runs there.
- **PR 6 (server):** creating an address that is already in use is refused with a plain sentence. Re-creating one of your own changes nothing.
- **PR 3 (bridges, lint rule, CLAUDE.md):** nothing visible. Mail's link and scroll helpers stay out of reach of any script a message could carry, and a new web view that turns JavaScript on fails lint until someone signs off.
- **PR 4 (retry):** on a flaky connection, creating a folder, saving rules or resetting a password no longer reports "already exists" or "changed elsewhere" for a change that landed. Archive, move, flag, delete and send behave as today.
- **PR 5 (outbox and local draft):** nothing visible normally. A delivered message is never sent again because its outbox file could not be deleted, and failures that used to vanish reach the debug log.
- **PR 7 (browser extension):** when an address can't be created, the extension shows the server's sentence instead of its raw reply, and a sign-up form is no longer sent with an address that could not be created unless you choose to.
- **PR 8 (server, after decision 8):** nothing visible. The admin create-address route answers an address that is already in use as `/new` does.

> **Withheld (2026-10-15):** The PR 1 and PR 6 lines are reworded to the level of the 1.31.2 changelog; what they said about C1's and W4's mechanism is withheld from this public copy under decision 1. Both fixes shipped in 1.31.2.

## Why

**C1. The composer and content it did not write (code path verified by reading; not reproduced; fixed in 1.31.2).** PR 1 fixed it as #2053 (`5eb7284`, "Apple: composer keeps only formatting from content it did not write"), released in 1.31.2 with the entry "Apple: **Safer reply and forward.** Quoting a message in a reply or forward no longer loads its remote images, and the composer keeps only the formatting of a quoted, pasted or dropped message." Its remote-image part is decision 7. No audit, scope doc or issue mentions it.

> **Withheld (2026-10-15):** This section's account of C1 (the code path, what carries it, what it allowed, the remote-image path and how the other clients compare) is withheld from this public copy under decision 1: it stays out of public forums until the fix is on prod for every client (for Apple, the App Store build people install), which is not yet confirmed. The fix shipped in 1.31.2.

**C2. Feed reader mode runs with JavaScript on (#1911, open, verified).**
- The reader document loads with `loadHTMLString(document, baseURL: pageURL)` (`CabalmailUI/Feeds/Reader/ArticleWebView.swift:171`). JavaScript is turned off only when the request's scheme is `about` (`:214`); with an https base URL the request carries https. The doc comment at `:5-9` says the opposite.
- The tester's harness ran the shipped expression and the vendored Readability on 2026-10-07: an inline script and an `onerror` handler both ran, and Readability keeps event-handler attributes (#1911 comment). Nothing else in the file turns JavaScript off (re-read at 50e6022).
- It is the default article path: subscriptions default to reader styling (`Feeds/Reader/FeedItemDetailViewModel.swift:172`, `:185`).
- Practical risk is low: the publisher's own script already ran on the live page in the same per-feed store, and this view has no native bridge. Reader mode adds execution, under the publisher's origin and cookies, of markup the publisher's policy might have blocked, in a document whose only content security policy is `upgrade-insecure-requests` (`Shared/BodyRendering/HTMLRewrite.swift:65-66`, `:75`, reached through `ArticleWebView.swift:259`). It is the one Apple reader that breaks the rule "The reader's web views render mail and feed HTML with JavaScript off" (00-working-agreements.md).

**C3. The mail reader's helper scripts share the message's script space.** The link and scroll bridges are installed in the page's own content world (`Shared/BodyRendering/HTMLBodyView+LinkBridge.swift:19-30`, `+ScrollBridge.swift:49-60`). Page JavaScript is off (`HTMLBodyView.swift:289`), so nothing reaches them today. Moving them to `WKContentWorld.defaultClient`, a separate script space the page cannot see, keeps it so if page script were ever allowed (the 2026-10-02 mail audit, audit 01, listed it as minor hardening; see "Background from the rearchitecture").

**W1. The transport retries every request once, whatever it does (verified).** `performWithRetry` replays any request after a lost connection, a timeout or a spurious cancel, with no method or endpoint check (`CabalmailKit/Sources/CabalmailKit/Auth/HTTPTransport.swift:74-91`, `:110-125`). The audits found this (audit 03 F13 and audit 06 instance 9, summarized in "Background from the rearchitecture") and asked for "idempotent methods only" (audit 06's T8 workstream), but took `/send` and `/move_messages` for POSTs; both are PUTs (`API/URLSessionApiClient+Messages.swift:275`, `:326`). The Lambdas show method is the wrong cut:
- Replays that help: `/move_messages`, `/set_flag` and `/purge_messages` act on UIDs. RFC 3501 6.4.8 says a missing UID is ignored, but `move_messages/function.py:44-46` says a STORE on moved UIDs is rejected. If so, a replayed archive (`mark_seen`, `:51`) fails its batch and answers 500 (`_shared/helper.py:478-497`, `:583-592`), and the client undoes a move that happened. PR 4 checks this on stage first. `/send` is deduped by Message-Id for 600 s: 200 duplicate for a confirmed delivery, 409 for one still in flight (`send/function.py:41`, `:282-307`; #909, closed).
- Replays that mislead (inferred): `/new_folder` answers 409 "already exists" (`new_folder/function.py:18-25`) and `/set_rules` is version-checked and answers 409 (`set_rules/function.py:312-352`), both PUT; `/rss_new_folder` mints a fresh id each time (`rss_new_folder/function.py:25-33`); Cognito `SignUp`, `ConfirmSignUp`, `ForgotPassword`, `ConfirmForgotPassword`, `RespondToAuthChallenge` and `VerifySoftwareToken` likely reject or re-issue on a second call (`Auth/AuthService.swift:203-242`, `:423`, `:450`; every Cognito call is a POST, `:333`).
- A cancelled backoff sleep falls straight through to the replay (`HTTPTransport.swift:82`, `try?`).

**W2. Swallowed errors on data paths (verified).**
- After a successful send the queue removes the entry with `try?` and logs "sent" (`Outbox/SendQueue.swift:245`). If the remove fails, the next drain sends it again: within 600 s the server answers "duplicate", after that it delivers a second copy. An entry with earlier failed attempts is already due, so the retry timer can fire with no delay and loop on `/send` until the file goes (inferred from `:206-221`, `:225-231`; a Kit test will settle it).
- Outbox list failures in `drain()` and `scheduleRetry` vanish (`SendQueue.swift:191`, `:208`).
- The local crash-safety copy of a draft is saved with `try?` and no log, every 5 s (`CabalmailUI/Compose/ComposeViewModel+Internals.swift:215`).
- The audit's third case (audit 06, instance 3), a message dropped after ten attempts, is already fixed: it is kept and shown (`SendQueue.swift:273-281`).

**W3. The send-queue binding is an unstored task (0.7 finding H, the Wave 0.7 notes' name for audit 06's instance 5, an ordering hazard in `CabalmailClient.init`; verified, harmless by inference).** `Task { await queue.bind(...) }` is never stored (`CabalmailClient.swift:228`), so `shutdown()` cannot cancel it. The ordering hazard the audit feared does not bite: `send(_:)` kicks a drain after enqueueing (`:324`), and `bind` replays the current reachability first (`SendQueue.swift:98-113`).

**W4. `/new` and an address that already exists (verified by reading; not reproduced; fixed in 1.31.2).** PR 6 fixed it as #2054 (`c467789`, "API: /new folds case and answers clearly for an existing address"), released in 1.31.2 with the entry "**Creating an address that is already in use.** The request now answers with a message saying so, and repeating a request for one of your own addresses leaves it as it was. New addresses are created in lower case."

> **Withheld (2026-10-15):** This section's account of W4 (the code path and its effects) is withheld from this public copy under decision 1: it stays out of public forums until the fix is on prod for every client, which is not yet confirmed, and the stage proof has not run. The fix shipped in 1.31.2.

> **Erratum (2026-10-17):** The stage proof has since run and passed (see PR 6's **Status:**). The rest of the note stands.

**W5. The browser extension and a refused address create (verified by reading on 2026-10-17 at `stage` 0b8d7ac; not reproduced).** Since 1.31.2, `/new` refuses an address that is already in use with a 409 and a sentence, under both `Error` and `message`. The extension did not change with it:
- The API client throws `ApiError(status, raw body)` (`extensions/shared/src/api/ApiClient.ts:59`). The background's catch-all flattens that to `{ ok: false, error: 'api', message: String(err) }` (`extensions/chrome/src/background.ts:161`), dropping the status, and the content side's `unwrap` throws `api: ApiError: {"Error": ...}` (`extensions/shared/src/messaging/client.ts:27`). The suggest popover shows that raw string (`extensions/chrome/src/overlay/overlay.tsx:127`), as does the popup's mint (`extensions/chrome/src/popup/popup.tsx:243`). Both mint random names, so a refusal there is rare, and neither sends a form.
- Typed addresses are where a refusal is likely, because the user picks the name. The submit guard's Create and submit (`extensions/shared/src/content/controller.ts:311-320`) catches a failed create silently and releases the form, so the site gets an address that was not created.
- The adopt banner's Create (`controller.ts:261-262`) leaves the rejection unhandled, so nothing is shown; the offer stays, so the submit guard asks again at submit and then takes the silent path above.
- `checkAdopt` compares the lower-cased typed address with the user's list exactly (`controller.ts:247`), so one of the user's own addresses stored in mixed case is offered for creation and refused.
- Adjacent (inferred, not reproduced): `/new` answers a repeat create for one of the caller's own addresses with the same 201 as a fresh create, and the background caches the address list for 30 s (`background.ts:72`, `:119`). An address the user created elsewhere within that window can therefore be "created" again, tracked as pending, and revoked on page hide (`controller.ts:354-357`) or when superseded (`:201`).

**W6. The admin create-address route and an existing address (verified by reading on 2026-10-17).** `/new_address_admin` creates an address for one or more named users. It is admin only (admin group, a per-caller rate limit and an audit log, `lambda/api/new_address_admin/function.py:29-35`), and no shipped client calls it: React defines `newAddressAdmin` (`react/admin/src/ApiClient.js:845`), but the admin Addresses view's New Address uses the ordinary `/new` and then Assign. It does not yet answer an address that is already in use the way `/new` has since 1.31.2, and it does not fold case. It was introduced by the 0.5.x user-management plan (`docs/0.5.x/user-management-plan.md:233`).

> **Withheld (2026-10-17):** What W6 does with an existing address is withheld from this public copy under decision 1, with W4.

## Where things stand

- #1911: open, bug, apple, verified; no PR. #1804: closed 2026-10-07 through release #1922. #909: closed 2026-08-05. #2043 (Release 1.31.0): merged on 2026-10-12, so nothing here waits on it. None of the 77 open issues covers C1, C3, W1, W2, W3 or W4; closed issues could not be searched reliably.

  > **Erratum (2026-10-15):** #1911 now has its fix: PR 2 merged to `stage` as #2056 (`5046716`), not yet released. The issue stays open until the hardening session's stage check (see the Progress table).

- The Apple apps have three web views: the composer (Kit), the feed article view and the mail reader. The mail reader is JavaScript-off, non-persistent and content-blocked, pinned by `CabalmailTests/ReaderWebViewConfigTests.swift:20-27`; real-WebView bridge tests are in `CabalmailTests/ReaderScrollBridgeTests.swift`. The composer has no content blocker.
- Editor tests use a real `WKWebView` (`CabalmailKitTests/RichTextEditorControllerTests.swift`, `RichTextEditorNavigationPolicyTests.swift`). CI runs them on the macOS Kit leg only; the iOS and visionOS legs skip them by name (`.github/workflows/apple.yml:257-266`). `CabalmailTests` compiles only into the macOS bundle (`apple/project.yml:681-685`), so a new real-WebView test there runs on macOS only.
- Transport tests: `HTTPTransportTests.swift`, `HTTPTransportCancellationTests.swift`. `ApiClientDecodeFailureTests.swift` already keeps a per-endpoint table plus a source scan anchored on `func decodeReply`; PR 4 follows that pattern and leaves those anchors alone. Queue tests: `SendQueueTests.swift`, `SendQueueStopTests.swift`, `OutboxWipeDuringAttemptTests.swift`; `Outbox` takes a `FileManager` (`Outbox.swift:66-77`), the seam for a failing remove.
- `HTTPTransport` is a public protocol with one requirement (`HTTPTransport.swift:10-12`) and six conformers in `CabalmailKitTestSupport`, plus private test actors.
- `ArticleWebView.swift` and `HTMLBodyView.swift` declare representables, so the platform-conditional ratchet exempts them. A new file must not add `#if os`. SwiftLint covers every folder of shipped Swift, `CabalmailUI` included, and the test folders (`apple/.swiftlint.yml:8-20`) and already has custom rules (`:64`).

## The plan

Each Apple PR adds tests that fail on the parent commit and an `Apple:` changelog fragment, or the `no-changelog` label when nothing is visible. One Apple PR open at a time; the Lambda PR starts no macOS jobs and can run beside them.

**Release rules.** #2043 merged on 2026-10-12. Nothing here merges while a later release PR is open, unless the maintainer says a fix should ride along. PRs 1, 2 and 6 go out together and are promoted as soon as they soak; PR 3 can ride the next release. android-parity.md's PR 1 (the Android twin of #1911) ships in PR 2's release. Session A yields CI to duo-support.md in the week before the device ships (about 2026-10-23). PRs 1, 4 and 5 edit Kit sources, so none may be open during kit-split.md's Kit freeze (its PRs C and D, which move `Compose/WebAssets` into a new target).

> **Erratum (2026-10-17):** android-parity.md's PR 1 does not ship in PR 2's release. It has not started, and the maintainer chose on 2026-10-17 to ship PR 2 without waiting for it; Android's feed reader keeps running article script until that PR ships in a later release.

> **Erratum (2026-10-15):** PRs 1 and 6 went out in 1.31.2 (PR #2055, dated 2026-10-14) without PR 2. PR 2 (#2056) and PR 3 (#2057) are on `stage`, not yet released, and android-parity.md's PR 1 has not started.

### Session A (Now): PRs 1, 2, 6, 3

**Before PR 1: reproduce C1 on the Mini (Remote Control).** Coordinate with the maintainer before signing in (a sign-in on one device can sign out another). Report privately to the maintainer.

> **Withheld (2026-10-15):** The reproduction recipe is withheld from this public copy under decision 1 (out of public forums until the fix is on prod for every client, not yet confirmed). The fix it tested shipped in 1.31.2.

**Status:** Not recorded (2026-10-15). This copy does not record whether the full app reproduction on the Mini ran; PR 1 has since merged (#2053) and shipped in 1.31.2.

**PR 1. Composer: keeps only formatting from content it did not write.**

**Status:** Done (2026-10-15). Merged as #2053 (`5eb7284`, "Apple: composer keeps only formatting from content it did not write") and released in 1.31.2 (PR #2055, dated 2026-10-14) with the entry "Apple: **Safer reply and forward.** Quoting a message in a reply or forward no longer loads its remote images, and the composer keeps only the formatting of a quoted, pasted or dropped message." Decision 1's condition (the fix in the App Store build people install) is not confirmed.

> **Withheld (2026-10-15):** PR 1's scope, files, tests, checks and risk described C1's mechanism and what carries it, so they are withheld from this public copy under decision 1. The fix shipped in 1.31.2; commit `5eb7284` holds the change.

**PR 2. #1911: feed reader mode runs no script.**
- Scope: two independent locks. First, in `ArticleWebCoordinator`, JavaScript follows a dedicated "reader document is loading" flag, set in `showReader` and cleared when that load commits; not the URL scheme, and not `showingReader`, because a link tapped inside the reader is decided while `showingReader` is still true (`ArticleWebView.swift:214-222`) and must load the live page with JavaScript on. Second, the reader document gets `script-src 'none'; object-src 'none'` and, under decision 3, `frame-src 'none'`, beside the existing policy meta. That second lock also covers a back or forward navigation that reloads the reader document from history (iOS turns on swipe-back, `:118`). Fix the doc comment at `:5-9`.
- Files: `Feeds/Reader/ArticleWebView.swift`; `Shared/BodyRendering/HTMLRewrite.swift` (reader mode only) or the reader document builder (`ArticleWebView.swift:247-260`); a pure policy type in a new file if that keeps the decision testable.
- Tests (`CabalmailTests`, macOS only): the policy over live, reader, link out of reader, toggle back, back/forward and subframe navigations; a real-WebView test that loads `ArticleReaderDocument.html(...)` with an https base URL, as #1911's harness did, and asserts neither an inline script nor an `onerror` ran.
- Verify: CI; on the Mini, macOS and the iOS and visionOS simulators, articles from two real stage feeds in reader mode (images, links, toggling back to a live page that still runs its script); stage TestFlight on iPhone. Close #1911 after the stage check.
- Risk: low. A flag left off breaks live pages visibly; the toggle-back check catches it.

**Status:** Merged to `stage` as #2056 (`5046716`, "Apple: feed reader mode runs no script from the article"), not yet released (2026-10-15). It fixes #1911: the reader rendering loads with page JavaScript off and leads with a content security policy refusing script, plugins and frames; Readability drops every video player; a link tapped in the reader leaves it only once its page commits. Stage check (2026-10-17): passed. The reader check on the Mini ran on macOS and the iOS and visionOS simulators, and the maintainer checked the stage TestFlight build on iPhone; #1911 was closed as completed on 2026-10-17. The check turned up two older issues, now filed: a link followed from reader view opens re-extracted in reader view rather than as the live page (#2060), and a table-view warning logged at launch on macOS (#2061). android-parity.md's PR 1, which this plan wanted in PR 2's release, has not started. The maintainer chose on 2026-10-17 to ship PR 2 without it. Released in 1.31.3 (PR #2062, 2026-10-17).

**PR 6 (server, after decision 6). `/new` answers clearly for an existing address.**

**Status:** Merged as #2054 (`c467789`, "API: /new folds case and answers clearly for an existing address") and released in 1.31.2 (PR #2055, dated 2026-10-14) with the entry "**Creating an address that is already in use.** The request now answers with a message saying so, and repeating a request for one of your own addresses leaves it as it was. New addresses are created in lower case." Stage proof (2026-10-17): passed, 17 checks of what `lambda/api/_shared/tests/test_address_create_existing.py` asserts, run by the maintainer on the Mini through the API as the two stage test accounts on a stage domain they share. The test addresses and their DNS records were gone after cleanup; no production data was touched.

> **Withheld (2026-10-15):** PR 6's scope, tests, checks and risk described W4's mechanism, so they are withheld from this public copy under decision 1. The fix shipped in 1.31.2; commit `c467789` holds the change.

**PR 3. Bridges in their own world, a lint rule, and the rule written down.**
- Scope: install both bridge scripts and their handlers in `WKContentWorld.defaultClient` (`WKUserScript(..., in:)`, `add(_:contentWorld:name:)`), and run the coordinator's own scripts (`HTMLBodyView.swift:426`, `:433`, `:449`) in that world through the completion-handler form that takes a content world, not the async one, which the code avoids on purpose because it traps on a nil result (`:429-432`). Add a SwiftLint custom rule over shipped sources that flags any `allowsContentJavaScript` assignment other than `= false`, with a reasoned `swiftlint:disable:next` at the composer and the article view. The tests (`ReaderWebViewConfigTests`, PR 2's real-WebView test) are the real guard; the rule catches the next new web view. Add an Apple bullet to `CLAUDE.md` naming the three web views, their JavaScript rule and the tests that hold it.
- Tests: page-world script sees no `cabalLink` handler; a click on a link still reaches the coordinator; `ReaderScrollBridgeTests` stays green. Confirm a message holding an element with `id="__cabalLinkBridge"` no longer affects the bridge's guard (`+LinkBridge.swift:56-57`). `no-changelog`.
- Verify: CI; Mini, a long newsletter on macOS (link menu, hover pill, scroll restore after relaunch).
- Lint cap: `HTMLBodyView.swift` counts 500 of SwiftLint's 500 `file_length` lines (mail-navigation-refactors.md's heads-up), so one more code line there fails CI. Keep the coordinator edits line-neutral or extract a type first (CLAUDE.md's rule). platform-conditionals.md's S1 PR 6 meets the same cap; whichever lands first does the extraction.

  > **Erratum (2026-10-15):** PR 3 landed first (#2057) and did not extract. It kept `HTMLBodyView.swift` code-line-neutral (one-for-one line changes; `apple/.swiftlint.yml` sets `ignore_comment_only_lines: true`) and extracted no type, so the file stays at its 500-line `file_length` cap and the extraction falls to the next PR that adds a code line there (platform-conditionals.md's S1 PR 6 in these plans).

- Risk: low. A handler in the wrong world fails silently (links open without the menu, scroll falls back to the 2 s poll); the click test catches it. `.swiftlint.yml` and `CLAUDE.md` are also edited by apple-ci-and-build-config.md and docs-and-bookkeeping.md: rebase onto theirs, and let this PR slip to Session B if theirs are open.

**Status:** Merged to `stage` on 2026-10-15 as #2057 (`f078467`, "Apple: reader bridges run in the app's own script world"), not yet released; label `no-changelog`. Both bridges, their handlers and the coordinator's restore and capture scripts run in `WKContentWorld.defaultClient`; a `content_javascript_enabled` SwiftLint custom rule has a reasoned `swiftlint:disable:next` at the composer and the feed article view; a `CLAUDE.md` bullet names the three web views, their JavaScript rule and the tests that hold them. Released in 1.31.3 (PR #2062, 2026-10-17).

### Session B (Next): PRs 4 and 5

**Before PR 4: check the replay premise on stage.** Call `/move_messages` twice with the same UIDs, once with `mark_seen: true` and once without, and `/set_flag` on UIDs that have moved away. If a STORE or MOVE on missing UIDs raises, a small Lambda PR first makes the server treat no-longer-present UIDs as success; only then do move and flag keep their retry.

**Status:** Not started (2026-10-15).

**PR 4. The transport retries only requests that are safe to replay.**
- Scope: GETs and the presigned S3 GET and PUT keep their retry. A write retries only when the per-endpoint table marks it replay-safe. The PR's first commit is that table: every endpoint the Kit calls (about 33 Lambda writes plus the Cognito operations), its replay behaviour, and the Lambda line it rests on. Likely safe: move, set_flag, purge, empty_trash, send, set_preferences, set_nav_state, subscribe and unsubscribe folder, set_favorite, the rss state, mark-all-read and update endpoints, push register and deregister, `/push_envelope` (a read sent as POST), `upload_url`, `/new` once PR 6 lands, and Cognito `InitiateAuth`. `mark_folder_read` is safe for this immediate retry only, not for queued replay, since it marks whatever is unseen when it runs (sqlite-mail-store.md decision 9). For `/new_folder` and `/set_rules` the table may say "retry, and a 409 on the replay means the first attempt landed", if the transport can tell the call site it replayed (inferred design); otherwise no retry. New endpoints default to no retry. A cancelled backoff sleep throws instead of replaying. The policy can key on method, path and Cognito's `X-Amz-Target` header (`AuthService.swift:335`), so the `HTTPTransport` protocol need not change; if a requirement is added instead, give it a default implementation in a protocol extension so the doubles keep compiling.
- Files: `Auth/HTTPTransport.swift`, a new policy file, `Auth/AuthService.swift`, `API/URLSessionApiClient*.swift` only if call sites must mark anything.
- Tests: `HTTPTransportTests` for both policies and the cancelled sleep; a table test that drives each `ApiClient` method through a transport failing once with -1005 and asserts the attempt count the table promises.
- Verify: CI; Mini, archive on macOS while toggling Wi-Fi.
- Changelog: an `Apple:` fragment (the error a user sees changes).
- Risk: medium. A read or move marked wrong loses its retry and shows an error after a background tap; the table test is the guard. Hand the finished table to sqlite-mail-store.md.

**Status:** Not started (2026-10-15).

**PR 5. No re-send after delivery, no silent outbox or draft failures.**
- Scope: the queue keeps an in-memory set of delivered ids; a delivered entry whose remove fails is never sent again in this process, the next drain only retries the remove, and the failure logs at error level. `drain()` and `scheduleRetry` log list failures. The local draft save logs its first failure and its recovery, not every 5 s; no banner, because the server copy still saves every 60 s. Store the binding task (W3) and cancel it in `shutdown()`. File a public issue for the outbox and draft quarantine (see Not in this plan).
- Files: `Outbox/SendQueue.swift`, `CabalmailClient.swift`, `CabalmailUI/Compose/ComposeViewModel+Internals.swift`.
- Tests: `SendQueueTests` with a `FileManager` whose `removeItem` throws: one `/send`, no tight loop, removal retried. A compose test that a failing draft store logs once.
- Verify: CI only. Changelog: an `Apple:` fragment (no duplicate delivery).
- Risk: low. Under sqlite-mail-store.md's recommended decision 6(a) the outbox stays separate, so this fix is permanent; keep it small anyway.

**Status:** Not started (2026-10-15).

**PR 7 (added 2026-10-17). The browser extension handles a refused address create (W5).**
- Why its own PR, not part of PR 4 or 5: it is TypeScript under `extensions/`, touches no Kit file (so the Kit freeze does not hold it), and runs different CI (see CI below). It can open before PR 4 or beside PRs 4 and 5.
- Scope:
  - Carry the refusal across the message boundary. The background maps an `ApiError` with status 409 to a new `BackgroundError` kind and puts the server's sentence (the body's `message`, else `Error`) in `message`; other API errors carry the sentence too when the body has one, not the raw JSON. `unwrap` throws a typed error that keeps the kind.
  - Suggest popover and popup: show the sentence. On a refusal the popover offers a fresh suggestion rather than retrying the same name.
  - Adopt banner Create: catch the failure, show the sentence at the field, and keep the offer, so the submit guard still holds.
  - Submit guard Create and submit: on a refusal because the address is already taken, do not release the form; show the sentence, with Edit address (cancel and focus the field) as the escape hatch and no submit-anyway. On "You already have this address as X" the address is the user's, so release the form. Other failures (network, 5xx) keep today's outcome but stop being silent: reuse the confirm-failed banner's Retry, Submit anyway and Cancel.
  - `checkAdopt` compares addresses ignoring case.
  - Before an adopt or guard create, read `/list` past the cache (one GET on an explicit click). If the address is already the user's, create nothing and track nothing, so the extension never revokes an address it did not create.
- Files: `extensions/chrome/src/background.ts`, `extensions/shared/src/messaging/messages.ts`, `extensions/shared/src/messaging/client.ts`, `extensions/shared/src/content/controller.ts` (and its `OverlayPort`), `extensions/chrome/src/overlay/overlay.tsx`, `extensions/chrome/src/popup/popup.tsx`. Check whether the Safari bundle reuses the Chrome overlay and background or has its own.
- Tests (`extensions/shared/test/controller.test.ts`, `apiClient.test.ts`, and the background's handler): a 409 from the fake background's `createAddress` leaves the guarded form unsubmitted and shows the sentence; the adopt banner's Create shows it and keeps the offer; the own-address-in-another-case refusal releases; a network failure shows the banner instead of releasing silently; a mixed-case own address is not offered; an address already in a fresh `/list` is neither created nor revoked on page hide.
- Verify: `npm run lint`, `npm test` and `npm run build` in `extensions/`; CI. On stage, with an unpacked build signed in as one stage test account: type an address the other test account owns into a sign-up form on a local test page, choose Create and submit, and see the sentence with the form held. Coordinate with the maintainer before signing in on the Mini.
- Changelog: one fragment, neutral under decision 1, with the `Apple:` prefix, because the Mac app embeds this extension's Safari bundle (`apple/scripts/sync-vendored.sh:89-100`) and TestFlight testers should see it; its body names the browser extension.
- CI: today only `extensions.yml` runs (one Linux job and one macOS Safari build). If apple-ci-and-build-config.md's PR gate has landed, `extensions/**` also starts `apple.yml`, so pace PR 7 like an Apple PR.
- Risk: low. A wrong mapping could hold a form the user meant to send; Edit address and Cancel keep the form usable, and the tests cover each branch.

**Status:** Not started (2026-10-17).

**PR 8 (added 2026-10-17; server, after decision 8). The admin create-address route answers an existing address as `/new` does (W6).**
- Scope: in `lambda/api/new_address_admin/function.py`, the handling PR 6 gave `/new`, shared through `_shared/helper.py` or copied, whichever is the smaller diff, with a sentence that points an admin to Assign. Fold username and subdomain to lower case. Tests beside `_shared/tests/test_address_create_existing.py`.
- Verify: pytest and pylint per `CLAUDE.md`; CI. A stage check needs an admin account, so it is the maintainer's or skipped.
- Changelog: a server fragment, neutral under decision 1.
- Risk: low; nothing calls it.

**Status:** In review (2026-10-17). The lookup `/new` used moved into `_shared/helper.py` as `stored_address_row_or_none`, and both create endpoints call it, so they share one definition of an existing address as they already share their input checks and DNS publisher. The admin route folds username and subdomain to lower case and, after its user checks and before any DNS or table write, answers an existing row in any case, whoever owns it, with a 409 whose sentence points to Assign; its put is conditional, so a create that lands between its read and its write gets the same 409. Refusals are audited as `refused`. Tests sit beside `/new`'s in `_shared/tests/test_address_create_existing.py` (unittest, as the suite runs in CI, not pytest). No stage check: it needs an admin account.

**Hotspots, one open PR at a time each.** `Compose/WebAssets/*` and `RichTextEditorController.swift` (kit-split.md PR D). `ComposeViewModel*.swift` (shared-load-error-state.md A1 and A4, mail-navigation-refactors.md PR 3, platform-conditionals.md). `HTMLBodyView*.swift` (platform-conditionals.md S1 PR 6; swift6-and-strict-checking.md B3). `ArticleWebView.swift` (shared-load-error-state.md leaves it to this plan while #1911 runs). `HTTPTransport.swift`, `AuthService.swift`, `URLSessionApiClient*.swift` (shared-load-error-state.md A2 and A3, kit-split.md). `SendQueue.swift`, `CabalmailClient.swift` (test-debt.md A4 and A5, sqlite-mail-store.md, account-isolation.md, kit-split.md). `.swiftlint.yml` and `apple.yml` (apple-ci-and-build-config.md; this plan does not expect to edit `apple.yml`). `CLAUDE.md` (docs-and-bookkeeping.md).

## Background from the rearchitecture

The sessions' briefs drew on four of the seven audits of the Apple clients written on 2026-10-02, which are not in the repo. What they need from them (the audits' own line numbers came from an earlier commit and are left out):

- **Audit 02 (feeds), F14, for PR 2:** "`ArticleWebView` reader rendering may not actually run with JavaScript off" (suspected; confidence low to medium, severity low). The doc comment says JavaScript is off for the reader rendering, but the reader HTML loads with `loadHTMLString(document, baseURL: pageURL)` and JavaScript is disabled only when the navigation request's scheme is `about`; with an https base URL it stays on for Readability's output, which keeps the publisher's markup, inline event-handler attributes included. The publisher's own script already ran on the live page in the same data store, so the practical risk is low, but it was the only web view in the app rendering third-party HTML with JavaScript on. Its recommendation: track "next navigation is the reader document" with a flag set in `showReader` instead of sniffing the scheme, or load the reader into a second `HTMLBodyView`-style view (JavaScript off, non-persistent); verify with a page containing `<img onerror>`.
- **Audit 01 (mail), for PR 3:** among the mail reader's strengths, `HTMLBodyView` is shared by mail and feeds and runs with content JavaScript off, a `nonPersistent` data store and a remote-content `WKContentRuleList`. As minor hardening it recommended installing the bridge `WKUserScript`s in `WKContentWorld.defaultClient` rather than the page world.
- **Audit 03 (Kit), F13, for Session B:** "Offline write queues and retry/backoff policy are per-feature and inconsistent" (confidence high, severity medium). The HTTP transport makes one retry after 250 ms for -1005, -1001 or a spurious cancel: "This also replays non-idempotent POSTs such as `/send` and `/move_messages`" (both are in fact PUTs; see W1). Mail send queues in `Outbox` JSON files, triggered by reachability or an enqueue, with no backoff and a silent drop after 10 attempts; flag, move and purge have no queue and return the error to the view model; RSS marks queue in a SQLite `pending` table and never give up; draft saves have no queue, by design, and show an error banner. It recommended one `PendingOperationQueue` abstraction (a persisted op log, an idempotency key, exponential backoff, a reachability trigger and a dead-letter state), backed by SQLite, for RSS marks, mail send and later mail flag and move.
- **Audit 06 (tests and robustness), for Session B:** its list of the most consequential instances includes:
  - Instance 3, swallowed errors on data-bearing paths: the local crash-safety copy of a draft saved with `try? await draftStore.save(snapshot)` and no log; `try? await outbox.remove(id:)` after a successful send, so a failed removal re-sends on the next drain (mitigated by the server's Message-Id dedupe, #1019); a queued message dropped after `maxAttempts` with only a `CabalmailLog.error` line (the "third case" in W2); and the sign-out cache wipe, all `try?` (account-isolation.md's).
  - Instance 5, unstructured tasks in `CabalmailClient.init`: the spotlight bind, the path-monitor invalidate and the send-queue reachability bind are fire-and-forget, and the client is "ready" before they bind, so a send enqueued before `queue.bind` runs is not retried on reachability until the next kick. Low severity, "an ordering hazard rather than a known bug". The Wave 0.7 notes list it as finding H (W3).
  - Instance 9: `URLSessionHTTPTransport` retries any request once on a transient `URLError`, POSTs included. Send is deduped server-side; other mutations (move, flag) are retried blind; a cancelled sleep (`try? await Task.sleep`) proceeds straight to the retry. Low to medium severity.
  - Its workstream T8, "Error and resilience pass" (goal: no silent loss), took in the draft-save, outbox-remove, dropped-message and sign-out-wipe sites, the "`HTTPTransport` retry policy (idempotent methods only)" and `Debouncer`/`Poller` utilities, with new tests for each surfaced failure as its check.

## How to start it

Two Claude Code sessions on the repo, Session B after Session A's release ships. Each reads this plan and `00-working-agreements.md` in `docs/1.x/post-wave-3/`. Session A also uses the feeds and mail audit findings in "Background from the rearchitecture" above. Session B also uses that section's Kit and robustness audit passages, and sqlite-mail-store.md in this folder. Both need Remote Control on the Mini and, there, the helper that reads the two stage test accounts' credentials from AWS Parameter Store at run time (never print them); Session A needs the maintainer or an admin for PR 6's stage domain grant.

> **Erratum (2026-10-16):** PR 6's proof needs no domain grant for test accounts 1 and 2, which already share stage domains; the helper serves test accounts 2 and 3, and those two may need one (see the erratum under decision 6). Session B starts once the release that carries PRs 2 and 3 (#2056 and #2057, on `stage` after 1.31.2) has shipped.

Session A brief:

> Workstream "Hardening: reader web content and write paths", Session A (PRs 1, 2, 6, 3). Read this plan (its "Background from the rearchitecture" section included) and `00-working-agreements.md` in `docs/1.x/post-wave-3/` first; the plan's handling note applies to everything you post to GitHub. Re-check its file:line references against current stage, and confirm no release PR is open before merging anything (#2043 merged on 2026-10-12). Then: (1) post a short scope doc to me with decisions 1, 2, 3, 6 and 7 quoted in full, each with its recommended answer, and one line per PR saying what I will see change; (2) reproduce C1 on the Mini as the plan describes and report privately; (3) open PR 1, then PR 2, one Apple PR at a time, pacing CI as the agreements say, with PR 6 beside them once I answer decision 6; then PR 3. Ask me to promote once PRs 1, 2 and 6 soak. Stop and ask if a fix needs a source-scan edit or a server change the plan doesn't name.

> **Erratum (2026-10-15):** This copy no longer describes the C1 reproduction that step (2) refers to (withheld under decision 1; see "Before PR 1"). Session A has posted its scope doc and opened PRs 1, 2, 6 and 3: PRs 1 and 6 shipped in 1.31.2, and PRs 2 and 3 are on `stage`; whether the step (2) reproduction ran is not recorded. What remains of Session A is in the Progress table: PR 6's stage proof, and closing #1911 after PR 2's stage check.

Session A remainder brief (added 2026-10-16, for a fresh session if the rearchitecture's Session A did not finish these; read the Progress table first and skip any step it marks done):

> Workstream "Hardening: reader web content and write paths", what remains of Session A. Read this plan and `00-working-agreements.md` in `docs/1.x/post-wave-3/` first; the plan's handling note applies to everything you post to GitHub until decision 1's condition is confirmed. (1) #1911: ask me whether the reader check on the Mini and my iPhone check of the stage TestFlight build have run. If the Mini check has not, run PR 2's Verify bullet on the Mini through Remote Control, with the agreements' rig rules; when both pass, close #1911 with a short comment. (2) PR 6's stage proof: ask me whether the proof script from 2026-10-15 has run and for its report. If it has not, or the script cannot be found, write one that shows on stage, through the API only, as test accounts 2 and 3, what `lambda/api/_shared/tests/test_address_create_existing.py` asserts: in the words of commit `c467789`, "A create for an address that already has a row, in any case, writes nothing: the caller's own row answers 201, anything else a 409 with a sentence the clients can show". It stops before writing anything if the two accounts share no stage domain and asks me for a grant, and it revokes every address it creates and confirms the test subdomain's DNS is gone. Report the result to me, not on GitHub. (3) Ask me whether the next release ships PR 2 without android-parity.md PR 1, or waits for it. Record each outcome in this plan's Progress table and Status lines through one docs-only PR.

Session B brief:

> Workstream "Hardening: reader web content and write paths", Session B (PRs 4 and 5). Read this plan (its "Background from the rearchitecture" section included) and `00-working-agreements.md` in `docs/1.x/post-wave-3/`, re-check line numbers against current stage, and confirm no promotion PR is open and kit-split.md's Kit freeze is not running. Post a short scope doc with decision 4 quoted in full and one line per PR. Run the stage replay check before PR 4, open PR 4 with its endpoint table as the first commit, then PR 5. Hand the finished table to sqlite-mail-store.md.

> **Note (2026-10-16):** "Kit freeze is not running" means no open PR for kit-split.md's PR C or PR D, whose freeze runs from C opening until D merges (kit-split.md, "Kit freeze"), and no freeze announced by the maintainer. "Hand the finished table to sqlite-mail-store.md" means recording it in that plan's decision 9 Status line, through the docs-only route in the agreements' "Working from the repo".

> **Added (2026-10-17):** Session B also opens PR 7, before or beside PRs 4 and 5, and PR 8 once decision 8 is answered. Its scope doc quotes decision 8 in full beside decision 4.

## Risks and checks

- **C1 may not reproduce.** If it turns out not to, PR 1 still lands as defense in depth with the same tests, and its priority drops to Next. Say which in the scope doc.

  > **Withheld (2026-10-15):** An example of how the reproduction could come out safe named part of C1's mechanism, so it is withheld from this public copy under decision 1. The fix shipped in 1.31.2.

- **Disclosure window.** From the first push of PRs 1 and 6 until prod (for Apple, the App Store build people install), the fix is readable in public. Testing on the Mini first and a prompt promote keep that short.
- **Over-blocking.** A sanitizer or policy that strips pasted formatting or `cid:` images. The round-trip tests and the paste check are the guard.
- **The replay table is inference until checked.** Each row names its Lambda line; the move and flag premise is checked on stage before PR 4.
- **Platform gaps.** CI skips WebKit-backed tests on the iOS and visionOS simulators, and `CabalmailTests` runs on macOS only. The Mini simulator passes in PRs 1 and 2 cover iOS and visionOS by hand.
- **Device checks hold Promote, not merge:** reply and forward on iPhone and Mac (PR 1); article reader mode on iPhone (PR 2). Add them to the maintainer's checklist.

## Not in this plan

- Android's feed reader runs with JavaScript on (`android/app/src/main/kotlin/com/cabalmail/android/ui/feeds/ArticleWebView.kt:121`, `:240-247`): android-parity.md PR 1, which mirrors decisions 2 and 3 and ships with PR 2.
- `/save_draft` leaves an orphan copy after a lost reply, with or without the retry (`save_draft/function.py:56-91`): sqlite-mail-store.md, in its Phase 4 decisions (PR 4.0).
- Lasting replay safety for queued writes (UIDVALIDITY preconditions): sqlite-mail-store.md decision 9. PR 4 only stops harmful immediate replays.
- Outbox and draft quarantine has no notice or recovery path; only a warning is logged (`CabalmailKit/Sources/CabalmailKit/Persistence/PersistedRecord.swift:64-71`). sqlite-mail-store.md keeps those stores out of its scope and no plan owns it, so Session B files a public issue to give it a tracker. A recovery UI is a feature, not hardening.
- The sign-out wipe's `try?` steps (`CabalmailClient+Maintenance.swift:17-41`): account-isolation.md PR C2.
- #1956 and #1957: sqlite-mail-store.md Phase 0. #1900 to #1903, #1918 and logging at the app's catch sites: shared-load-error-state.md.
- The Linux composer (Phase 5 of `docs/1.x/linux-client-plan.md`, not started) loads the same `editor.html` and `editor-bridge.js` (`:777`), so it inherits PR 1 as long as the sanitizer stays in that file.
- Readability runs in the publisher page's own world, so the page can shape its output. Not pursued: the page controls the DOM anyway, and the reader document is inert after PR 2.
- #1804's server remainder: declined by default (decision 5). Shipping it would mean a distinct 404 sentence and a check of React's and Android's handling; Android needs `message_raw` omitted, never null (android-parity.md).

## Sources

- Repo at 50e6022: `apple/CabalmailUI/Feeds/Reader/ArticleWebView.swift:5-9,109-123,168-223,247-260`; `FeedItemDetailViewModel.swift:160-190`; `apple/CabalmailUI/Shared/BodyRendering/HTMLBodyView.swift:285-297,410-452`; `HTMLBodyView+LinkBridge.swift:19-30,54-60`; `HTMLBodyView+ScrollBridge.swift:49-60`; `HTMLRewrite.swift:10-30,60-80`; `apple/CabalmailUI/Compose/ComposeViewModel.swift:270-285`; `ComposeViewModel+Internals.swift:199-216`; `apple/CabalmailKit/Sources/CabalmailKit/Auth/HTTPTransport.swift:1-126`; `Auth/AuthService.swift:161-242,327-340,423-470`; `API/URLSessionApiClient.swift:83,169`; `API/URLSessionApiClient+Messages.swift:261-326,395-410`; `+Push.swift:26-46`; `+Rss.swift:21-140`; `+Rules.swift:16`; `CabalmailClient.swift:224-229,318-326`; `Outbox/SendQueue.swift:98-113,185-285`; `Outbox/Outbox.swift:66-77`; `Persistence/PersistedRecord.swift:1-95`; `apple/.swiftlint.yml:1-25,64`; `apple/project.yml:676-724`; `.github/workflows/apple.yml:225-270`; `react/admin/src/Email/MessageOverlay/index.jsx:105,296-307`; `lambda/api/send/function.py:36-42,282-307`; `move_messages/function.py:15-52`; `_shared/helper.py:176-190,470-497,575-595,1303-1316`; `fetch_inline_image/function.py:30-50`; `docs/1.x/linux-client-plan.md:100-103,775-779`.

  > **Withheld (2026-10-15):** The entries that located C1's and W4's code paths, carriers and effects are withheld from this source list under decision 1. Both fixes shipped in 1.31.2, in commits `5eb7284` and `c467789`.

- GitHub (read 2026-10-12): #1911 (open, locked; tester reproduction comment of 2026-10-07); #1804 (closed 2026-10-07 by release #1922); #909 (closed 2026-08-05); #2043 (open, Release 1.31.0); open-issue list of 77, none covering C1, C3 or W1 to W4.
- Records of the 2026-10 Cabalmail Client Architecture project (the audits of 2026-10-02, the workstream scope docs, soak notes and threads), summarized above where this plan uses them; they are not in the repo.
- Sibling plans in this folder, read 2026-10-12: android-parity.md (decision 2, PR 1, releases), sqlite-mail-store.md (decisions 6 and 9, Phase 4 list, hand-offs), kit-split.md (PR D, Kit freeze, PR E), shared-load-error-state.md (hotspots, #1915), docs-and-bookkeeping.md (PR 2), test-debt.md (A4, A5), platform-conditionals.md (S1 PR 6), duo-support.md (hotspot table), mail-navigation-refactors.md, apple-ci-and-build-config.md.

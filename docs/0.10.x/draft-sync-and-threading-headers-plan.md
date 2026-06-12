# Draft Sync and Threading Headers Plan (APPEND / Message-ID parity)

## Context

Issue #371 rerouted the Apple clients from a hand-rolled IMAP stack onto the
Lambda API, and [`ApiBackedImapClient`](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift)
documents the trade-offs of that path: no APPEND, and envelopes that omit
Message-ID. A feature audit (2026-06) traced two concrete capability gaps to
those constraints:

- **Cross-device draft sync.** Drafts live only in the local `DraftStore`
  (5-second autosave); a reply started on the Mac cannot be resumed on the
  phone. The Android plan hit the same wall and explicitly deferred it
  ([`docs/1.1.x/android-client-plan.md:618`](../1.1.x/android-client-plan.md)).
- **Threading.** Without Message-ID / In-Reply-To / References at the
  envelope level, conversation grouping is impossible, and today even
  replies sent from the Apple client carry no threading headers
  ([`Draft.swift:6-7`](../../apple/CabalmailKit/Sources/CabalmailKit/Compose/Draft.swift)).

A closer audit shows the server is further along than the client-side
comments suggest. The pieces that already exist:

- `/send` already performs an IMAP APPEND for drafts: `draft: true` routes to
  `_save_draft` → `append_drafts`, which creates the Drafts folder if needed
  and APPENDs with `\Draft \Seen`
  ([`lambda/api/send/function.py:95-96,147-163,356-365`](../../lambda/api/send/function.py)).
  The React client uses it for explicit saves
  ([`react/admin/src/ApiClient.js:210-223`](../../react/admin/src/ApiClient.js)).
- `/send` already accepts `message_id`, `in_reply_to`, and `references` in
  `other_headers`, validates them against header injection, and writes them
  into the outbound MIME
  ([`send/function.py:284-311,337-354`](../../lambda/api/send/function.py)).
- `/fetch_message` already returns `message_id`, `in_reply_to`, and
  `references`; the React `MessageOverlay` threads replies from them
  ([`react/admin/src/Email/MessageOverlay/index.jsx:93-95,210`](../../react/admin/src/Email/MessageOverlay/index.jsx))
  and CabalmailKit already decodes them
  ([`ApiClientTypes.swift:129-140`](../../apple/CabalmailKit/Sources/CabalmailKit/API/ApiClientTypes.swift)).
- The Swift models and compose pipeline are pre-wired: `Envelope` has
  `messageId` / `inReplyTo` fields
  ([`Models/Envelope.swift:39-50`](../../apple/CabalmailKit/Sources/CabalmailKit/Models/Envelope.swift)),
  `ReplyBuilder` computes threading from them
  ([`ReplyBuilder.swift:227-246`](../../apple/CabalmailKit/Sources/CabalmailKit/Compose/ReplyBuilder.swift)),
  and the Apple `ApiClient` send request already carries the `draft` flag and
  `other_headers`
  ([`ApiClient.swift:215-255`](../../apple/CabalmailKit/Sources/CabalmailKit/API/ApiClient.swift)).

What is actually missing is narrow:

1. **Envelope payloads omit the threading headers.** `envelope_dict` emits
   UID, date, subject, from/to/cc, flags, attachment flag, and priority —
   nothing else ([`lambda/api/_shared/helper.py:663-687`](../../lambda/api/_shared/helper.py)).
   So the Apple client populates `Envelope.messageId` with nil and
   `ReplyBuilder` degrades to headerless replies.
2. **The draft APPEND has no lifecycle.** `_save_draft` returns only
   `{"status": "saved"}` — no UID — and every save creates a new message.
   There is no replace, no discard (the purge endpoints are deliberately
   trash-scoped), and therefore no way to run an autosave-style sync loop
   without littering the Drafts folder with stale copies.

This plan bridges both gaps. It deliberately stops at the data layer:
threading *UI* is a separate plan that consumes these fields.

## Goals

- `/list_envelopes` and `/search_envelopes` emit `message_id`,
  `in_reply_to`, and `references` per envelope, in the same wire shape
  `/fetch_message` already uses, as a purely additive JSON change.
- Replies from the Apple client carry correct In-Reply-To / References
  headers.
- The draft path gains full lifecycle semantics: save returns the new
  draft's UID, save can atomically replace a prior copy, and a draft can be
  discarded — all scoped to the Drafts folder.
- The Apple clients sync drafts across devices through that path; local
  `DraftStore` autosave remains the editing buffer.
- Every phase is additive and independently shippable; the React client is
  unaffected until it opts in.

## Non-goals

- Conversation/threading UI. This plan provides the data prerequisite only;
  grouping, thread rendering, and mute-thread are a separate plan (the
  0.9.x search plan and 0.10.x large-mailbox plan both already point there).
- Real-time updates. IDLE/push is owned by the 1.1.x push notifications
  plan; nothing here changes the polling model.
- Reviving native IMAP in any client.
- React draft UX changes. The React explicit-save flow keeps working
  unchanged; adopting replace/discard there is optional follow-up.
- A server-side draft storage format beyond standard MIME. Drafts stay
  readable by any IMAP consumer.

## Current state (audit)

### Envelope serialization is a single choke point

Both `/list_envelopes` and `/search_envelopes` build their payloads through
the shared `envelope_dict` + `ENVELOPE_FETCH_KEYS`
([`helper.py:663-687`](../../lambda/api/_shared/helper.py),
[`list_envelopes/function.py:27-28`](../../lambda/api/list_envelopes/function.py),
[`search_envelopes/function.py:369-374`](../../lambda/api/search_envelopes/function.py)).
One change covers both endpoints — and a mistake breaks both, so the change
ships with the existing local-test harness exercised for each function.

Two of the three missing fields are already fetched: the IMAP `ENVELOPE`
response that `imapclient` parses carries `message_id` and `in_reply_to`;
`envelope_dict` simply does not serialize them. `References` is not part of
`ENVELOPE` and needs the existing header fetch widened (the key already
pulls `X-PRIORITY` the same way).

### The draft path has no lifecycle

`append_drafts` is create-only. Dovecot supports UIDPLUS, so the APPEND
response already includes `APPENDUID <uidvalidity> <uid>` — the Lambda just
discards it. Replace and discard need `\Deleted` + `UID EXPUNGE`, which
`imapclient` supports (`expunge(messages=...)`), guarded by a UIDVALIDITY
check so a mailbox reset can never expunge the wrong message. Deletion is
deliberately unavailable elsewhere: `purge_messages` / `empty_trash` are
trash-scoped by design, and that safety posture should be mirrored here —
draft expunge is Drafts-scoped only.

### The Apple client is one decode away on threading

`ApiBackedImapClient.makeEnvelope` documents that `messageId` is omitted
"and no behavior depends" — stale on both counts once the fields exist
([`ApiBackedImapClient.swift:281-283`](../../apple/CabalmailKit/Sources/CabalmailKit/IMAP/ApiBackedImapClient.swift)).
`ReplyBuilder.threading(for:)` already reconstructs References as
`[in_reply_to] + [message_id]`; with a real References list available it
should prefer `original.references + [original.message_id]` per RFC 5322.

## Recommendations

### Layer 1 — Envelope threading headers (Lambda)

- Widen the header fetch:
  `BODY[HEADER.FIELDS (X-PRIORITY)]` → `BODY[HEADER.FIELDS (X-PRIORITY REFERENCES)]`.
  `imapclient` keys the response dict by the requested atom, so the lookup
  inside `envelope_dict` changes in lockstep — keep the constant and the
  lookup adjacent, and parse the returned header blob with
  `email.parser.HeaderParser` rather than the current bare `split()`, since
  it now carries two headers with folding.
- Extend `envelope_dict` with `"message_id"`, `"in_reply_to"`, and
  `"references"` as **lists of angle-bracketed ids**, matching the
  `/fetch_message` wire shape so client decoders are shared.
- Cap emitted `references` at the last 20 ids. Deep threads grow this
  header without bound, envelopes are fetched 50 at a time, and RFC 5322
  itself sanctions trimming old ids.
- Compatibility: additive JSON only. The React envelope consumer and the
  CabalmailKit decoder both ignore unknown fields; no coordination needed.

### Layer 2 — Apple client threading consumption

- Decode the new fields in the envelope payload and populate
  `Envelope.messageId` / `Envelope.inReplyTo`; add `references: [String]`
  to the `Envelope` model and let `ReplyBuilder` prefer it when non-empty.
- Quick win that can ship *before* Layer 1: when replying from an open
  message, thread from the `/fetch_message` response already in hand
  (`FetchMessageResponse` carries all three fields today). This fixes
  headerless replies with zero server change; Layer 2 then extends correct
  threading to reply-from-list and future conversation grouping.
- Cleanup: retire the stale comments in `Draft.swift` and the
  `makeEnvelope` doc, and update the CLAUDE.md Apple-client constraint note
  (it currently lists "no Message-ID" as a standing limitation).

### Layer 3 — Draft lifecycle (Lambda)

Add a dedicated `/save_draft` function (new entry in the API function map at
[`terraform/infra/modules/app/locals.tf`](../../terraform/infra/modules/app/locals.tf);
the per-function build picks the new directory up automatically):

- **Request**: the `/send` compose payload shape, reusing
  `validate_outbound_headers`, `load_attachments` (same `MAX_ATTACHMENTS` /
  `MAX_TOTAL_ATTACHMENT_BYTES` caps), and `compose_message` from the shared
  module — plus optional `replaces_uid` + `replaces_uidvalidity`, and an
  `op` of `save` (default) or `discard`.
- **Response**: `{"status": "saved", "uid": N, "uidvalidity": V}`, parsed
  from the UIDPLUS `APPENDUID` response code.
- **Replace**: APPEND the new copy first; only then flag the old UID
  `\Deleted` and `UID EXPUNGE` it, and only if the selected Drafts folder's
  UIDVALIDITY matches `replaces_uidvalidity`. On mismatch, keep both copies
  and report `"replaced": false` — never guess.
- **Discard** (`op: discard`): same guarded expunge, Drafts folder only —
  mirroring the trash-scoping of the purge endpoints.
- `/send` gains an optional `discard_draft_uid` (+ uidvalidity) so
  send-from-draft cleans up the server copy after successful SMTP delivery,
  best-effort in the same spirit as the queued Sent copy.
- Maintenance behavior: interactive and IMAP-only, so reuse the
  `MaintenanceError` → `maintenance_response` pattern `_save_draft` uses
  today; clients retry rather than fail during an IMAP roll.
- `/send`'s existing `draft: true` branch delegates to the same shared code
  and keeps its current response shape, so React is untouched.
- Log hygiene: no subject/body/recipient logging, matching the 0.9.x search
  plan's privacy-constrained observability stance.

**Markdown round-trip.** The Apple compose pipeline's canonical form is
Markdown; drafts are stored as standard `text/plain` + `text/html` MIME.
First pass: resume by converting HTML back with turndown, which the editor
stack already bundles. Edge-case lossiness is acceptable for drafts; if it
proves annoying, a `text/markdown` alternative part (stripped at send) is
the escape hatch. Rejected: stuffing Markdown into a custom header — drafts
should stay standards-shaped for any IMAP consumer.

### Layer 4 — Apple client draft sync

- `DraftStore` remains the live editing buffer; the 5-second local autosave
  cadence does **not** go to the server. Server saves happen on compose
  close-without-send, on explicit save, and at most on a long debounce
  (~60 s) — bounding Lambda invocations and EFS churn.
- Sync loop: save → record `(uidvalidity, uid)` → next save passes them as
  `replaces_*`; send → `discard_draft_uid`; open Drafts folder → existing
  `/list_messages` + envelopes; resume → `/fetch_message` raw → MIME parse
  (the client already parses full MIME for the `fetchPart` workaround) →
  `Draft` via turndown.
- Conflict policy, first pass: last-writer-wins keyed on
  `(uidvalidity, uid)`; a failed replace falls back to save-as-new, so the
  worst outcome is a duplicate draft, never a lost one.
- Offline: queue the server save the way `SendQueue` queues sends; the
  local copy is already durable.

## Risks and trade-offs

- **Shared serializer change.** One typo in `ENVELOPE_FETCH_KEYS` breaks
  both list and search. Mitigated by the single-constant design, the
  per-function local-test harness, and stage soak.
- **References growth.** Capped at 20 ids; clients must tolerate the cap
  (reply threading only ever appends one id to what it received).
- **Wrong-message expunge.** The UIDVALIDITY guard plus Drafts-only scoping
  bounds the blast radius to "extra draft copy survives."
- **Drafts retain Bcc** (deliberate — the user is still composing). Already
  true today; the fetch path only ever returns a mailbox's own messages.
- **Send dedupe interaction.** `/send` claims the Message-Id before SMTP;
  drafts saved without a Message-Id stay outside the dedupe window until
  send assigns one. No change needed, but worth a test case.
- **Rollout.** This is a data-plane change (Lambda API surface, message
  flow), so it is not eligible for direct-to-prod scaffolding; every phase
  routes through stage.

## Phased rollout

1. **Phase 0 — reply threading quick win (client-only).** Thread Apple
   replies from the `/fetch_message` response. No server dependency.
2. **Phase 1 — envelope fields (Lambda).** `helper.py` fetch-key widening +
   `envelope_dict` fields + caps. Verify React renders unchanged. Stage,
   then prod.
3. **Phase 2 — Apple envelope consumption.** Decode fields, extend
   `Envelope` with `references`, prefer real References in `ReplyBuilder`,
   retire stale constraint comments (including the CLAUDE.md note).
4. **Phase 3 — draft lifecycle (Lambda + Terraform).** `/save_draft` with
   replace/discard, `/send` `discard_draft_uid`, API Gateway wiring. Stage
   soak before prod.
5. **Phase 4 — Apple draft sync.** Sync service over `DraftStore`, Drafts
   folder resume UX, offline queueing.
6. **Phase 5 — documentation.** As-implemented docs at the top level of
   `docs/`, changelog fragments per shipped phase.

Each phase is independently revertible; Phases 1-2 and 3-4 are parallel
tracks once Phase 0 lands.

## Future work

- Conversation/threading UI plan (consumes Phases 1-2).
- Android client draft sync — the 1.1.x plan's deferred item is unblocked
  by Phase 3 as-is.
- React adoption of replace/discard for parity with the Apple draft flow.

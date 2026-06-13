# Draft sync and threading headers

As-implemented notes for the 0.10.x draft-sync-and-threading work (plan:
[`docs/0.10.x/draft-sync-and-threading-headers-plan.md`](./0.10.x/draft-sync-and-threading-headers-plan.md)).
Two related capabilities ship together: envelope payloads now carry the RFC
5322 threading identity, and the Drafts folder gained a real server-side
lifecycle that the Apple clients use for cross-device draft sync.

## Envelope threading headers

`/list_envelopes` and `/search_envelopes` emit three additional fields per
envelope, in the same wire shape `/fetch_message` has always used — lists of
angle-bracketed ids:

```json
{
  "message_id":  ["<abc@mail.example>"],
  "in_reply_to": ["<parent@elsewhere.example>"],
  "references":  ["<root@elsewhere.example>", "<parent@elsewhere.example>"]
}
```

- `message_id` and `in_reply_to` come from the IMAP `ENVELOPE` response the
  endpoints already fetched; `references` rides the existing header fetch,
  widened from `X-PRIORITY` to `X-PRIORITY REFERENCES` and parsed with
  `email.parser.HeaderParser` (both live in
  [`lambda/api/_shared/helper.py`](../lambda/api/_shared/helper.py), behind
  the shared `envelope_dict` / `ENVELOPE_FETCH_KEYS` choke point that keeps
  the two endpoints in lockstep).
- `references` is capped at the **newest 20 ids**. Deep threads grow the
  header without bound, envelopes are fetched ~50 at a time, and RFC 5322
  sanctions trimming old ids. Reply threading only ever appends one id to
  what it received, so the cap is loss-free for composing.
- The change is purely additive JSON. The React envelope consumer and the
  CabalmailKit decoder both tolerate the fields' absence, so client and
  server can deploy in either order.

The Apple clients consume the fields two ways: `ReplyBuilder` prefers the
real `references` chain (falling back to `[In-Reply-To, Message-ID]` for
pre-rollout envelopes), and the message-detail view overlays the headers
parsed from the fetched body onto the envelope before seeding a reply — so
replies from an open message thread correctly even against cached envelopes
that predate the rollout.

## Draft lifecycle: `/save_draft`

`/send` with `draft: true` remains the create-only path the React client
uses (response shape unchanged). The new `/save_draft` endpoint adds the
lifecycle an autosave-style sync loop needs. It takes the `/send` compose
payload (same sender authorization, header-injection validation, attachment
staging, and MIME assembly, now shared via
[`lambda/api/_shared/compose.py`](../lambda/api/_shared/compose.py)) plus:

| Field | Meaning |
|---|---|
| `op` | `save` (default) or `discard`. |
| `replaces_uid`, `replaces_uidvalidity` | The prior server copy this save supersedes (or, for `discard`, the copy to remove). Both or neither. |

Responses:

- `save` → `{"status": "saved", "uid": N, "uidvalidity": V, "replaced": bool}`
  — the new copy's coordinates parsed from the UIDPLUS `APPENDUID` response
  code.
- `discard` → `{"status": "discarded", "discarded": bool}`.

Safety posture, mirroring the trash-scoping of the purge endpoints:

- **Drafts-only.** No request parameter selects the folder; every operation
  is pinned to the top-level `Drafts` mailbox.
- **UIDVALIDITY-guarded.** Replace appends the new copy *first*, and only
  then expunges the old one — and only if the selected folder's UIDVALIDITY
  matches `replaces_uidvalidity`. On mismatch both copies survive and the
  response reports `"replaced": false`. The worst outcome of any failure
  mode is an extra draft copy, never a lost one.
- **Cache hygiene.** An expunged copy's cached raw body
  (`{user}/Drafts/{uid}/raw` in the cache bucket) is deleted, as
  `purge_messages` does.
- During a planned IMAP roll the endpoint returns the standard 503
  maintenance signal; clients retry rather than fail.

`/send` additionally accepts `discard_draft_uid` + `discard_draft_uidvalidity`:
after successful SMTP delivery it best-effort expunges that Drafts copy (same
guard, same scope), so send-from-draft cleans up the server copy in the same
spirit as the queued Sent copy. Failures are logged, never surfaced — the
mail has already been delivered.

Drafts deliberately retain Bcc (the user is still composing), and a draft
saved without a Message-Id stays outside `/send`'s dedupe window until send
assigns one.

## Apple client draft sync

`DraftStore` (5-second local autosave) remains the live editing buffer and
the crash-recovery story. Server saves happen:

- on compose **close-without-send** (always),
- on a **60-second debounce** while composing (skipped while empty, while a
  send is running, or while another server save is in flight).

The sync loop is last-writer-wins keyed on `(uidvalidity, uid)`: each save
records the returned coordinates and passes them as `replaces_*` on the
next one; send passes them as `discard_draft_uid`; the compose window's
"Discard draft" also discards the server copy. A failed replace degrades to
save-as-new server-side, so a conflict produces a duplicate draft, never a
lost one.

Resume: opening a message in the Drafts folder offers **Edit Draft**, which
seeds compose from the already-fetched message — recipients and subject from
the envelope, Bcc and threading from the message headers, and the body from
the `text/plain` part. Both first-party composers are Markdown-canonical and
emit the Markdown source as the text part, so the round trip is lossless for
our own drafts; an HTML-only draft from a foreign client falls back to
editing the raw HTML through the Markdown buffer (Markdown passes inline
HTML through, so content is preserved).

Two deliberate simplifications relative to the plan:

- **Offline handling** does not add a second persistent queue alongside the
  outbox. The local copy is already durable, the debounce loop retries
  silently, and close-without-send surfaces a banner on hard failure (the
  local copy survives either way). The plan's `SendQueue`-style queue can be
  added later if this proves insufficient.
- **Resume** prefers the `text/plain` part over an HTML → Markdown turndown
  conversion. It is lossless for first-party drafts and avoids pushing a
  WebKit dependency into the resume path; turndown remains available in the
  editor for the cross-pane import buttons.

## Operator notes

- `save_draft` is a standard API-function Lambda (entry in
  `terraform/infra/modules/app/locals.tf`, 512 MB like `/send` because it
  stages attachments). The per-function build picks the directory up
  automatically; `_shared/compose.py` is bundled into any zip whose handler
  imports it (see `.github/scripts/build-api-one.sh`).
- Server draft saves are interactive IMAP writes against the single-task
  IMAP tier; the Apple client's 60-second debounce floor exists to bound
  Lambda invocations and EFS churn. Keep that in mind before shortening it.

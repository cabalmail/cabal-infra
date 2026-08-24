# Browser Extension OTP Fill (tentative)

**Status:** Tentative sketch, not on the roadmap. Written 2026-08-24.
Extends the browser extension
([`docs/1.x/browser-extension-plan.md`](../1.x/browser-extension-plan.md));
assumes the base extension (shared core, auth, form detection,
suggest/adopt flows) has shipped. That work is planned for 1.x but
carries no minor-release target at the time of writing. Kept out of
that plan deliberately: the base extension's stated posture is that
it never looks at mail content, and this feature changes that trust
posture, so it gets its own scope decision.

## Context

The base extension collapses address minting into the sign-up form.
The natural companion: when a site emails a one-time code, surface it
on the page where the user needs it, instead of making them switch to
a mail client, find the message, memorize six digits, and switch back.

The two features meet at the extension's own best moment. The first
message to arrive at a freshly minted address is very often the
verification code itself, so mint-address → receive-code → offer-code
is one continuous flow on one page — the strongest demo the extension
has. It also overlaps the base plan's procmail clear-on-receive hook:
the same mail arrival that confirms the pending address carries the
code we want to surface.

**Prior art and honest value assessment:** Apple platforms autofill
codes from Messages, and Safari on macOS can offer codes surfaced
from Mail.app. That used to work for Cabalmail: with the mailbox
configured in Apple Mail over public IMAP, macOS surfaced Cabalmail
codes. The private mail-plane work removed public IMAP, so no
platform mail client can index a Cabalmail inbox anymore, and the
capability is gone on every platform — not just the Chrome/non-Apple
gap that always existed. The honest framing is therefore not
"adoption driver" — address minting is the adoption driver — but
"restored capability": someone who chooses Cabalmail for the minting
should not have to sacrifice a convenience other mail platforms
offer. Per-site addresses even upgrade the capability rather than
merely restoring it: they give an origin-binding signal no generic
mail-based OTP filler has (see below). It remains the most
security-sensitive thing the extension could do, and the design cost
is dominated by getting that right, not by the plumbing.

## Goals

- When a code arrives while an OTP field is present in the active tab,
  offer it within a few seconds of delivery.
- Offer, never silently fill. Filling always takes an explicit user
  gesture, and the offer always shows where the code came from and
  which address received it. Never auto-submit.
- The extension never gains standing access to message content. Code
  extraction happens server-side; the extension only ever sees
  candidate codes with metadata.
- Use the minted-address relationship as origin-binding evidence
  where it exists, and treat its absence as normal rather than
  suspicious. Email-code sign-in is a routine mechanism — some sites
  eschew passwords entirely — and most addresses carry no site
  association today. Binding exists to make contradiction detectable
  (see Origin binding), not to gate the offer.

## Non-goals

- SMS codes. Cabalmail has no SMS surface.
- Magic links. Different mechanic (navigation, not transcription);
  possibly a later tie-in with the private-link handoff, but not here.
- Background inbox monitoring. The extension watches for codes only
  while an OTP field is on screen; there is no always-on poll and no
  standing notification channel in v1.
- Auto-submit after fill, ever.
- Restoring public IMAP so platform mail clients can do this instead.
  The private mail plane is settled; this feature exists inside that
  boundary.

## Design sketch

### OTP field detection

`autocomplete="one-time-code"` is the WHATWG-blessed signal and the
easy case. The rest is heuristics: numeric `inputmode`, `maxlength`
4–8, name/label/placeholder vocabulary ("code", "verification",
"2fa", "one-time", localized variants), and the segmented pattern of
N single-character inputs. This rides the base plan's scoring engine
— a new classification alongside `signup`/`signin`, tested against a new
`fixtures/otp/` corpus category collected with the same snapshot
tool.

### Mail awareness: poll on demand; push is future work

The API path has no IDLE, so delivery cannot push to the extension
today. v1 polls, but only inside a tight trigger window: an OTP field
is detected in the focused tab (or the user clicks the field chip),
poll every few seconds for a bounded window (~2–5 minutes), then stop
and require a fresh gesture. No OTP field, no traffic.

A push channel is the better long-term shape — the APNs/FCM dispatch
infrastructure exists for the native clients, and a Web Push
equivalent targeting the extension service worker is plausible — but
it is real backend work and v1 does not need it: the poll window is
short, user-triggered, and rare.

Rejected: always-on polling (cost and privacy posture both wrong),
and client-side IMAP anything (the extension stays API-backed).

### Extraction: server-side endpoint

New Lambda, sketch name `fetch_otp_candidates`: authorized like every
other endpoint, reads the caller's INBOX via the existing helper.py
master-user path, scans only messages received within the last N
minutes, runs code extraction, and returns candidates:

```json
{ "candidates": [ { "code": "834921",
                    "sender_domain": "github.com",
                    "recipient": "f8x3p_qr@bzkw4mnv.cabalmail.com",
                    "comment": "github.com",
                    "received_at": "2026-08-24T17:03:11Z",
                    "message_id": "<...>" } ] }
```

Extraction heuristics live server-side: subject plus `text/plain`
part, digit runs of 4–8 with nearby context vocabulary, common
alphanumeric formats, ranked when a message yields several matches.

Why server-side rather than the extension fetching bodies via the
existing `/fetch_message`: it keeps full message content out of the
extension entirely (the narrowest possible privacy claim in the store
listings — "the extension never reads your mail, it asks the server
whether a code arrived"); it centralizes parsing where the mail
already is; and the endpoint is reusable by the native clients later
(Android has no mail-based system OTP autofill either — a notification
offering the code is the same feature on a different surface).

The mail path is untouched. No procmail involvement, no milter, no
new delivery-time hooks — this is a read-side poll like every other
API endpoint.

### Origin binding — the crux

Real-time phishing kits work precisely by relaying the legitimate
site and harvesting the OTP the victim transcribes. A filler that
makes transcription frictionless makes that attack frictionless too,
so the binding design is the feature. Ranked signals:

1. **Recipient address is bound to this site.** The base plan's
   suggest flow defaults the address `comment` to the page hostname,
   so even before any mapping store exists, a code arriving at an address
   whose comment matches the current origin is a strong match. The
   address-metadata model (below) makes this rigorous.
2. **Sender domain matches the page origin** (eTLD+1). The generic
   signal every mail-based filler has. Decent, not sufficient alone.
3. **No binding signal.** Normal, not suspicious. Email-code sign-in
   is routine — for passwordless sites it is the entire auth flow —
   and most existing addresses carry no site association, so absence
   of evidence cannot justify demotion or extra confirmation steps
   without punishing the legitimate common case into warning
   fatigue. The offer appears with sender and recipient shown
   plainly, and nothing more.

Binding is therefore not a gate on offering; it is what makes the
dangerous case detectable. A code whose recipient address is bound
to site A, offered while the user is on site B, is exactly the
real-time phishing shape, and that gets loud treatment — a warning,
not a dimmed chip. A warning can only fire on positive evidence,
and today that evidence is sparse: extension-minted addresses carry
comment-equals-hostname; everything else carries nothing.

### Address metadata: the fuller answer (out of scope, recorded here)

The confident version of OTP-to-site ascription is richer metadata
on `cabal-addresses` rows, along the lines of:

- correspondence mode: two-way vs receive-only
- which sender domains (or MX) are authorized or expected to send
  to this address
- personal vs corporate
- associated websites

This is a superset of the base plan's deferred site-to-address
mapping store, and its value reaches well beyond OTP fill:
expected-sender metadata is leak detection (mail arriving at a
vendor-scoped address from anyone but that vendor means the address
was leaked or sold), correspondence mode can drive send-side UI, and
associated websites powers the deferred sign-in autofill. Way out of
scope for this feature; recorded here because it is the model that
would let OTP ascription be confident rather than heuristic. If
pursued, it becomes its own tentative doc.

### UX

A chip anchored to the detected OTP field, same Shadow-DOM overlay
machinery as the base plan's popover: while polling, a quiet "watching
for a code…" state with a cancel affordance; on arrival, "Fill 834921
— github.com → f8x3p_qr@bzkw4mnv…". Multiple candidates render as a
short list. Filling uses the base plan's event-dispatch sequence;
segmented inputs get per-character dispatch. The toolbar popup offers the same
candidates with a copy button, as the fallback for OTP fields the
detector missed.

Optional post-use cleanup, settings-gated and default off: after a
successful fill, offer to mark the code message read or move it to
trash via the existing `/set_flag` / `/move_messages` endpoints.
Codes are single-use noise; the mailbox does not need to keep them.

## Backend additions

- `fetch_otp_candidates` Lambda + API Gateway route (Cognito
  authorizer), scoped to INBOX and a recency window. Purely additive.
- Nothing else in v1. Push channel, if pursued, is its own follow-up.

## Open questions

1. **Poll economics.** Each poll is a Lambda invocation doing an IMAP
   master-user login. At a 3–5s interval for a 2–5 minute window this
   is fine in absolute cost, but the per-call IMAP login is the slow
   part — worth measuring whether a coarser interval (or reusing
   `list_envelopes` timestamps to skip body work) keeps latency
   acceptable.
2. **How much address metadata must exist before v1?** With unbound
   codes treated as normal, none: comment-equals-hostname already
   gives mismatch detection for extension-minted addresses, and the
   metadata model upgrades confidence later. Leaning ship with
   nothing new.
3. **Safari iOS.** On-demand polling driven by the content script
   should survive Safari's aggressive service-worker lifecycle since
   every poll is triggered by a live page; verify before committing
   to iOS parity.
4. **Extraction quality bar.** Server-side extraction needs its own
   fixture corpus (real OTP mails from a spread of senders) and the
   same regress-against-corpus discipline as the form detector.
5. **Notification surface for native clients.** If the endpoint ships,
   an Android/Apple "copy code" notification is nearly free — same
   endpoint, push-triggered. Separate plan, but the endpoint contract
   should not preclude it.

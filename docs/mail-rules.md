# Mail rules

Users can author an ordered list of rules that the IMAP tier applies to
every arriving message before it reaches the inbox: file it into a
folder, flag it, mark it read, forward it, answer it with an auto-reply,
or discard it. Rules are composed in a structured editor in the native
clients, stored server-side, and compiled into per-user procmail on the
imap tier — user input never becomes procmail syntax directly.

This page is the user-facing reference (what rules can and cannot do)
plus enough operator context to debug a delivery. The security model,
the compiler design, and the escaping rules live with the code in
`docker/shared/compile-user-rules.py`.

## Editing rules

The editor lives in each native client's Settings:

- **iOS / iPadOS / visionOS** — Settings → Mail rules.
- **macOS** — Settings (⌘,) → Mail rules, which opens the editor as a
  sheet.
- **Android** — Settings → Mail rules.

All clients edit the same server-side list. Changes auto-save about a
third of a second after you stop editing; the indicator at the bottom of
the list shows saving / saved / error states. If two devices edit at
once, the second save is rejected and that device offers a single
**Reload** — last writer wins, unsaved edits on the loser are discarded.
There is no merge.

The list shows one row per rule with an enable switch and a one-line
summary. Rules can be added (blank or from a starter template),
duplicated, deleted, and reordered; a disabled rule is kept but never
evaluated.

## Conditions

A rule has zero or more conditions, ANDed together. Each condition is a
field plus a case-insensitive *contains* match on that field. **A rule
with no conditions matches every message** — that is how a vacation
reply is built, and also how mail is accidentally mass-filed, so watch
the summary line.

| Field   | What is searched                                            |
| ------- | ----------------------------------------------------------- |
| From    | The `From:` header line, display name included              |
| To      | The `To:` header line                                       |
| Cc      | The `Cc:` header line                                       |
| Subject | The `Subject:` header line                                  |
| Body    | The message body                                            |

Because matching runs against the raw header line, a condition value of
`aws.amazon.com` matches any From address at that domain, and a value of
`Jane Smith` matches a display name. There are no regular expressions,
no OR, and no NOT — the value is always a literal substring.

**There is no BCC field, deliberately.** Blind-carbon-copy recipients
are removed from the headers before a message is transmitted — that is
what makes them blind — so by the time a message arrives there is
nothing for a BCC condition to match. A control that silently never
fires would only mislead, so it is not offered.

## Actions

Each rule picks at most one **destination** and any combination of
**extras**.

Destinations (mutually exclusive):

- **Move** — deliver into a folder you pick.
- **Copy** — deliver a copy into one or more folders you pick. On a
  rule that ends processing, the original is delivered to the inbox as
  well; on a rule that continues, the message passes to later rules
  (and lands in the inbox only if nothing further files it).
- **Archive** — deliver into your `Archive` folder.
- **Delete** — discard the message permanently at delivery time. It is
  not moved to Trash and cannot be recovered.
- **None** — don't deliver anywhere; extras still apply. On a rule that
  ends processing the message stays in the inbox.

Move, Archive, and Delete are only offered on rules that end
processing. While **Continue to the next rule** is on, the destination
choices narrow to Copy and None — a rule that continues passes the
message along, so any delivery it makes is necessarily a copy, and the
editor says so instead of letting a "Move" quietly behave as one.
Turning Continue on while Move or Archive is selected converts the
destination to Copy, carrying the folder; the delivered mail is
identical either way, only the label is more honest. (Rules saved as
Move or Archive with Continue on by older clients are likewise shown
and saved as Copy.)

Folder pickers offer only folders that already exist. **The system never
creates a folder on your behalf** — not when you save a rule and not at
delivery time. If a rule's destination folder is later deleted, the rule
is skipped (the message stays in the inbox) until you pick another
folder; the editor flags the missing folder. Archive is not
special-cased: with no `Archive` folder an Archive rule is skipped too,
which is why the editor offers an explicit "Create Archive folder"
button when you pick that action.

Extras (independent; all disabled when the destination is Delete —
there is no message left to act on):

- **Flag** — the message arrives flagged, and/or tagged with any of
  the custom flags you have defined in Settings → Flags (the rule
  editor's flag picker offers the classic flag plus your palette). If
  you later delete or disable a custom flag, rules that set it are
  skipped entirely — pick a different flag or remove it from the rule
  to re-arm them.
- **Mark as read** — the message arrives read.
- **Forward** — send a copy to up to 10 addresses. The forward carries
  the original message; forwarded copies are stamped with a loop-guard
  header so a pair of rules forwarding at each other cannot storm.
- **Reply** — send an automatic plain-text reply (see below).

## Auto-replies

Reply is the vacation-responder: a plain-text body you write, sent back
automatically to whoever mailed you.

- **The reply comes from the address the message was sent to** — the
  matched recipient address, not a system address — so it lands in the
  sender's thread and reads as a normal reply. Note the trade-off: an
  auto-reply confirms to the sender that the address is live, which
  matters if the rule matches a vendor-scoped address you may later
  burn.
- Each sender gets **at most one reply per 7 days**, however many
  messages they send in the window.
- Replies are capped at **100 per 24 hours** per account; past the cap
  they are silently suppressed until the window rolls over.
- Replies are never sent to bulk senders, mailing lists, mailer-daemons,
  or other auto-submitted mail, and every reply is itself marked
  `Auto-Submitted: auto-replied` (RFC 3834) so responders elsewhere
  ignore it. These guards are built in and not configurable.
- The body is plain text only — no images, no links that unfurl, no
  rich text.

## Order and spill-through

Rules run top to bottom in the order you arrange them. By default the
first rule whose conditions match is the last one that runs for that
message. Turning on a rule's **Continue to the next rule** lets
evaluation keep going after it fires, so later rules also see the
message. A Delete rule never continues (there is nothing left to
evaluate).

A continuing rule never settles the message's fate: it passes the
message along, and any delivery it makes is a copy (which is why its
destination can only be Copy or None). **The inbox is the fallback
destination** — a message that runs off the end of the list without a
rule ending processing for it is delivered to the inbox, copies and
decorations intact. The editor refuses a continuing rule that neither
files, flags, marks read, forwards, nor replies; it would have no
effect at all.

Flag, custom flags, and Mark-as-read on a continuing rule with
destination None *decorate* the message: the marks are carried along
and applied wherever the message ends up — a later rule's folder, or the inbox
fallback. That is how "file receipts into Receipts AND flag anything
from billing" composes from two rules, **decorators above filers**:

1. From contains `billing` → destination None, Flag, Continue on.
2. Subject contains `receipt` → Move to Receipts.

A billing receipt matches rule 1, picks up the flag, continues, and
rule 2 files it — one flagged message in Receipts, nothing extra in
the inbox. A billing message that is not a receipt runs off the end
and lands in the inbox, flagged. Order matters: a decorator below the
filer never sees a receipt (the filer ends processing first).

On a rule that itself delivers — a Move, an Archive, a Copy, or a
terminal None — Flag and Mark-as-read apply to that rule's own
deliveries (plus any decorations picked up earlier), as they always
have.

## Limits

| Limit                              | Value          |
| ---------------------------------- | -------------- |
| Rules per account                  | 100            |
| Conditions per rule                | 10             |
| Condition value length             | 500 characters |
| Forward addresses per rule         | 10             |
| Copy destinations per rule         | 10             |
| Reply body length                  | 4000 characters|
| Auto-replies per account per 24h   | 100            |
| Auto-replies per sender            | 1 per 7 days   |

## When changes take effect

Saving publishes a change notification that the imap tier picks up
within seconds; a periodic fallback recompiles every ~15 minutes even if
the notification is lost. Rules apply only to mail that arrives after
compilation — they never re-run against mail already delivered, and
there is no retroactive "apply to existing messages".

## Why didn't my rule fire?

Work down this list:

1. **Is the rule enabled?** Disabled rules are skipped entirely.
2. **Did an earlier rule already match?** Without spill-through, the
   first matching rule wins. Check the rules above it in the list.
3. **Does the destination folder still exist?** A rule whose folder was
   deleted is skipped and the message stays in the inbox; the editor
   marks the folder as missing.
4. **Are the rule's custom flags still in your palette?** A rule that
   sets a flag you have since deleted or disabled is skipped entirely
   until you update it (Settings → Flags shows the palette).
5. **Is the condition matching what you think?** Matching is a literal
   substring against the raw header line. `To contains` matches the
   `To:` header — not the envelope recipient — so mail where your
   address only appears as a BCC will not match a To condition.
6. **Had the change propagated yet?** A rule saved moments before a
   message arrived may not have compiled in time; anything after the
   ~15-minute worst case is in effect.
7. **For replies:** the same sender within 7 days, bulk/list/auto-
   submitted mail, and anything past the daily cap are all silently
   suppressed by design.
8. Still stuck? An operator can check the compile log (below) for a
   `compile_skip_rule` line naming your rule and the reason.

## Operator notes: where rules live

- **Source of truth**: the `cabal-user-rules` DynamoDB table, one row
  per user, the whole ordered rule list JSON-encoded with an
  optimistic-concurrency version. Every write is audited to
  `cabal-user-rules-audit` (JSON Patch diff per save, 90-day TTL) —
  incident response for "who set the rule that caused this" starts
  there.
- **Compiled form**: `/etc/procmail-user/<user>.rc` inside the imap
  container, regenerated atomically by
  `/usr/local/bin/compile-user-rules.py` on every reconfigure (SNS
  fan-out from `set_rules`, plus the 15-minute fallback). Every local
  user gets a file; no rules means an empty file. Procmail includes it
  from the user's `~/.procmailrc` after the system recipes and before
  default delivery.
- **Compile logs and metrics**: the compiler logs `compile_ok` /
  `compile_skip_rule` / `compile_skip_user` lines (with per-rule skip
  reasons such as `folder_not_found`, `folder_not_set`,
  `unsafe_folder`, `flag_not_in_palette` — the last meaning the rule
  sets a custom flag that is no longer in, or is disabled in, the
  user's palette, the flag twin of `folder_not_found`) to the imap tier's CloudWatch log group, and emits
  per-run counts to the `Cabal/UserRules` metric namespace
  (`CompiledRules`, `SkippedRules`, `FailedUsers`, `CompileOkUsers`).
- **Alarms** (always on, independent of the optional monitoring stack;
  no delivery channel is wired while monitoring is off — check the
  CloudWatch console): `cabal-rules-selftest-failures` (a compiler
  regression is blocking imap task start),
  `cabal-rules-skipped-anomaly` (skip counts far above their recent
  baseline — usually a bad schema or compiler change),
  `cabal-rules-outbound-burst` (rule-driven forwards/replies leaving at
  loop-like rates), and `cabal-set_rules-duration-p99` (editor saves
  are lagging past the 1s budget).
- **Per-delivery decisions**: procmail's own log at
  `~/.procmail/log` in each user's home on the mailstore shows which
  recipe fired for which message, with each compiled rule tagged by its
  `r-…` id. The reconfigure loop bounds these logs at ~5 MB
  (copytruncate, one prior copy kept).
- **A compiler regression cannot ship silently**: a golden-file
  self-test gates both the Docker image build and container start; a
  runtime failure holds sendmail down so ECS replaces the task while
  the previous task keeps serving.
- **Outbound path caveat**: rule-driven forwards and auto-replies are
  submitted through the imap tier's sendmail, like system bounces —
  they are not DKIM-signed (only smtp-out signs). Deliverability of
  forwarded mail to strict receivers is accordingly best-effort.

Users see none of the above; their contract is the editor plus this
page's behavior descriptions.

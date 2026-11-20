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

- **iOS / iPadOS / visionOS** — Settings → Rules.
- **macOS** — Settings (⌘,) → Rules.
- **Android** — Settings → Mail rules.

All clients edit the same server-side list. Changes auto-save about a
third of a second after you stop editing; the indicator at the bottom of
the list shows saving / saved / error states. If two devices edit at
once, the second save is rejected and that device offers a single
**Reload** — last writer wins, unsaved edits on the loser are discarded.
There is no merge.

On the Apple clients the same screen holds a second list, **Feed
items**, under the mail rules (headed **Email messages**): the rules for
feed items, described under [Feed rules](#feed-rules) below. Everything
on this page up to that section is about mail rules.

The list shows one row per rule with an enable switch and a one-line
summary. Rules can be added (blank or from a starter template),
duplicated, deleted, and reordered; a disabled rule is kept but never
evaluated. To reorder on iPhone, iPad and Vision Pro, tap Edit and drag,
or choose Move Up or Move Down from a rule's long-press menu. On the Mac,
choose Move Up or Move Down from a rule's ⋯ menu or its right-click
menu; Android has the same items in each rule's menu.

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

- **Flag** — the message arrives carrying whichever flags you switch
  on in the rule editor, which lists them as Settings → Flags does. The
  built-in flag, "Flagged" until you rename it, is that list's entry for
  the mail server's own flag, and a rule can always set it; the rest
  are the custom flags you have defined. If you later delete a custom
  flag, rules that set it are skipped entirely — pick a different flag
  or remove it from the rule to re-arm them.
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
   sets a flag you have since deleted is skipped entirely until you
   update it (Settings → Flags shows the palette).
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

## Feed rules

A second list of rules, kept beside the mail rules, applies to feed
items instead of messages: when the feed fetcher first sees a new item,
it evaluates each subscriber's feed rules against it and flags the item
or marks it read for that subscriber, before any device opens the feed.

The Apple clients edit feed rules in Settings → Rules, in the **Feed
items** list under the mail rules. Android has no editor for them yet.
Clients that predate feed rules are unaffected: they never see the list,
and saving mail rules from one leaves it exactly as it was.

The list works as the mail rules' does: one row per rule with an enable
switch and a one-line summary; add (blank, or the "Flag matching items"
template on the first-run screen), duplicate, delete and reorder; and
the same auto-save, indicator and **Reload**. The two lists are saved
together and share one version, so an edit to either on one device is a
conflict for a device still holding the older set. A new blank rule
arrives switched off: with no conditions it would match every new item
in every feed.

In the editor a rule has a name, the **Feed** it applies to (**All
feeds**, or one of your subscriptions), its conditions, and its actions.
A rule with no action switched on is saved, and the editor and its row
say that it does nothing yet. If you unsubscribe from a rule's feed the
rule stays and matches nothing; the editor says so until you pick
another feed or All feeds.

A feed rule is simpler than a mail rule. It has conditions and the three
marks a mail rule can make, and nothing else: no folder, no forward, no
reply, no "continue".

| Condition | What is matched |
| --------- | --------------- |
| Feed      | One subscription, exactly. Without it the rule covers every feed you subscribe to. At most one per rule. The editor shows it as the rule's Feed, not as a condition row. |
| Title     | The item's title; case-insensitive *contains*. |
| Author    | The item's author; case-insensitive *contains*. |
| Summary   | The text of the item's summary and of its body; case-insensitive *contains*. Markup is not text: a tag or attribute never matches. |

Conditions are ANDed, and a rule with none matches every new item, as
for mail. The actions are **Flag** (the built-in flag), **custom flags**
and **Mark as read**.

How feed rules differ from mail rules:

- **Every matching rule applies.** Nothing is being filed, so there is
  no "first match wins" and no order of evaluation; an item picks up the
  marks of every enabled rule that matches it.
- **A rule runs once per item, when the fetcher first sees it.** It does
  not run again if the publisher later edits the item, and it does not
  reach back to items that were already there when the rule was saved or
  when you subscribed. The one case that looks retroactive is a feed
  nobody on the system subscribed to before: its first fetch brings in
  its whole backlog as new items, and a rule with no Feed condition
  usually applies to all of them. Usually, because that first fetch is
  started as you subscribe and can run before your subscription is
  visible to it; then the backlog gets no marks.
- **A rule that sets a deleted custom flag is skipped whole,** as a mail
  rule is, including its Flag and Mark-as-read, until you edit it.
- **Mark as read never overrules you.** If you have already marked the
  item read or unread yourself by the time the rule is applied, your
  mark stands. Flags are only ever added.
- **It is best effort.** If the rules cannot be read at the moment an
  item arrives, or the fetch that brought it in fails part-way, the
  item is still stored and simply gets no marks; the rule is not
  retried for it.

Limits: 100 feed rules per account, 10 conditions per rule, 500
characters per condition value.

### On the wire

`/get_rules` answers `feedRules` beside `rules`, and `/set_rules`
accepts it beside `rules` under the same `expectedVersion`:

```json
{
  "rules": [],
  "feedRules": [
    {
      "id": "r-0123456789ab",
      "name": "Releases",
      "enabled": true,
      "conditions": [
        {"field": "feed", "value": "<subscription_id>"},
        {"field": "title", "value": "release"}
      ],
      "flag": false,
      "flags": ["cabal-flag-03"],
      "markRead": false
    }
  ],
  "expectedVersion": 4
}
```

- `feedRules` is optional in a save. **Absent means "leave the stored
  list alone"**; an empty list clears it; `null` is refused. `rules` is
  still required, so a client that edits feed rules sends both lists.
  The Apple clients send `feedRules` only when the feed list differs
  from the server's last answer, so an edit to the mail rules alone is
  the request an older build sends.
- The two lists share one `version`: a feed-rule save racing a mail-rule
  save on another device gets the same 409 as two mail-rule saves.
- Condition fields are `feed`, `title`, `author` and `summary`. Any key
  or field outside this shape is refused, as for mail rules, and each
  list is checked against its own fields: a mail rule cannot carry
  `title`, nor a feed rule `subject`.
- Ids are server-assigned and unique across both lists.
- A validation error for a feed rule carries `"list": "feedRules"`
  beside `rule` (the index in that list), `field` and `error`. Errors
  for mail rules are unchanged and carry no `list`.
- Whether a `feed` value still names one of the caller's subscriptions,
  and whether a slot is still in the palette, are not checked at save
  time, for the reason folder targets are not. The fetcher decides: a
  rule for a subscription that is gone matches nothing.

## Operator notes: where rules live

- **Source of truth**: the `cabal-user-rules` DynamoDB table, one row
  per user, the whole ordered rule list JSON-encoded with an
  optimistic-concurrency version. The feed rules are a second
  JSON-encoded attribute of the same row, `feedRules`, under the same
  version. Every write is audited to
  `cabal-user-rules-audit` (JSON Patch diff per save, 90-day TTL, with
  mail rules under `/rules/` paths and feed rules under `/feedRules/`) —
  incident response for "who set the rule that caused this" starts
  there.
- **Compiled form**: `/etc/procmail-user/<user>.rc` inside the imap
  container, regenerated atomically by
  `/usr/local/bin/compile-user-rules.py` on every reconfigure (an SNS
  message from `set_rules` on every save but one that changed only the
  feed rules, from `set_preferences` when a custom flag
  is added or deleted, or from any address change, plus the 15-minute
  fallback). Every local
  user gets a file; no rules means an empty file. Procmail includes it
  from the user's `~/.procmailrc` after the system recipes and before
  default delivery.
- **Compile logs and metrics**: the compiler logs `compile_ok` /
  `compile_skip_rule` / `compile_skip_user` lines (with per-rule skip
  reasons such as `folder_not_found`, `folder_not_set`,
  `unsafe_folder`, `flag_not_in_palette` — the last meaning the rule
  sets a custom flag that is no longer in the user's palette, the flag
  twin of `folder_not_found`) to the imap tier's CloudWatch log group, and emits
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

- **Feed rules have no compiled form.** The compiler never reads
  `feedRules`, and a save that changes only feed rules is not published
  to the imap tier. The `rss_fetch` worker reads the list when a fetch
  inserts an item and writes the outcome to the subscriber's row in
  `cabal-rss-user-item-state`; what it logs and counts is in
  [rss.md](rss.md), "Feed rules at ingest".

Users see none of the above; their contract is the editor plus this
page's behavior descriptions.

# User-Defined Mail Rules Plan

## Context

Cabalmail users want their inbox to do work for them without their having to
write procmail recipes by hand. This version introduces a safe, UI-driven mail
rules feature: a user composes an ordered list of rules in a structured editor
on the web or a native client, those rules are stored server-side, and the
IMAP tier evaluates them against every arriving message before delivery.

Each rule has:

- **Name** -- free-text label the user picks.
- **Trigger conditions** -- zero or more `(field, value)` clauses, ANDed
  together. Field is one of `from`, `to`, `cc`, `subject`, `body`. The
  only operator is case-insensitive `contains`. An empty list matches every
  message. (The design brief lists a sixth field, BCC, but BCC recipients
  are not present in the headers a message arrives with -- see
  [BCC is not offered](#bcc-is-not-offered) -- so this plan drops it rather
  than ship a condition that silently never matches.)
- **Actions** -- one mutually-exclusive destination plus any subset of
  independent extras (see [Data model](#data-model) for the full set).
- **Precedence** -- the rule list is ordered; rules are evaluated top-to-
  bottom and the first one whose conditions match fires its actions.
- **Spill-through** -- a per-rule toggle: after this rule fires, halt
  processing (default) or proceed to the next rule.

The design handoff at
[docs/1.3.x/design_handoff_mail_rules/](design_handoff_mail_rules/) defines
the React-side look and feel pixel-perfectly. The Apple clients (iOS,
iPadOS, macOS, visionOS) re-implement the same feature using native
SwiftUI widgets -- a Settings-window tab on macOS, a navigation row in the
shared Settings view on iOS / iPadOS, a sheet or window where appropriate
on visionOS.

The handoff omits one action that the spec calls for and that this plan
covers: **Reply** with a user-specified body (auto-reply / vacation
reply). See [Reply action](#reply-action) for the additions to the data
model, UI, and procmail compiler that Reply requires.

## Goals

- Let users author and reorder mail-handling rules from any first-party
  Cabalmail client (React web app, iOS, iPadOS, macOS, visionOS).
- Have the IMAP tier honor those rules deterministically on every incoming
  message, in the user's declared order, with the user's spill-through
  intent respected.
- Keep the procmail surface inside the container *server-owned*: user input
  shapes rules, but never lands as raw procmail syntax. Every condition
  value, folder name, forward target, and reply body is whitelisted,
  escaped, and bounded before it reaches `/etc/procmail-user/<user>.rc`.
- Preserve the pending-address procmail hook introduced in
  [1.2.x](../1.2.x/browser-extension-plan.md): user rules MUST run *after*
  the system pending-confirm rules and MUST NOT overwrite, suppress, or
  collide with them.
- Survive a malformed rule set without breaking mail delivery for the user.
  A rule that fails to compile is skipped with a logged warning; the rest
  of the user's rules continue to apply; the message still delivers to the
  default mailbox.

## Non-goals

- **Power-user procmail.** Boolean operators between conditions (OR, NOT,
  parenthesized groups), regex operators in the value field, header-field
  extraction beyond the six standard fields, custom procmail recipes
  pasted by the user. The "safe UI" framing means we deliberately do not
  expose escape hatches.
- **Outbound rules / send-time rules.** This version evaluates against
  incoming mail only. Rules that trigger on sent mail (e.g. CC-yourself-
  on-everything) are out of scope.
- **Filter by date, size, attachment presence, sender domain reputation,
  spam score, calendar-invite type.** Future work; the five fields above
  are the v1 cut.
- **Cross-folder actions (move a message between folders after the fact).**
  Rules fire once, at delivery time. They never re-run against mail already
  filed in a folder. Out of scope.
- **Server-side mail search to retroactively apply a new rule to existing
  messages.** A natural follow-on, but it has its own design surface
  (IMAP search across all folders, batched move/flag operations, progress
  reporting). Deferred.
- **Per-folder rule sets.** Rules apply to the whole inbox.
- **Sharing or templating rules across users.** Future work, possibly an
  admin-curated set.

## Relation to prior work

[1.2.x's browser extension plan](../1.2.x/browser-extension-plan.md)
introduces a separate system-level procmail surface for pending-address
confirmation -- per the
[Coexistence section of that plan](../1.2.x/browser-extension-plan.md#:~:text=Coexistence%20with%20the%20planned%20end-user%20procmail%20framework),
the two pieces are explicitly designed to live in adjacent procmail
niches without colliding. This plan is the realization of that "end-user
procmail framework."

The ordering constraint set by 1.2.x is the load-bearing invariant:

1. **System pending-confirm rules run first.** They live in
   `/etc/procmail-pending.rc`, are `:0 wc` (wait, copy -- side-effect-only;
   never divert delivery), and clear the `pending` flag on a freshly
   minted address the moment real mail arrives at it.
2. **User-defined rules run second.** They live in
   `/etc/procmail-user/<username>.rc`, are owned and regenerated by this
   plan's machinery, and may freely divert delivery -- move into a
   folder, reply, forward, delete -- because the pending-confirm rules
   already finished their bookkeeping before user rules see the message.
3. **The default delivery (`DEFAULT=$HOME/Maildir/`) runs last.** Already
   in [`docker/imap/configs/procmailrc`](../../docker/imap/configs/procmailrc).
   It catches everything that no user rule consumed.

The single edit that wires this all up sits in
[`docker/imap/configs/procmailrc`](../../docker/imap/configs/procmailrc),
and the single edit that propagates the include lines to each user's
`~/.procmailrc` sits in
[`docker/shared/sync-users.sh`](../../docker/shared/sync-users.sh). Both
edits are additive and idempotent; both grow by exactly one INCLUDERC
line in this version. See [Phase 2](#phase-2--procmail-compiler-and-imap-tier-integration).

**1.2.x ships first.** This plan assumes 1.2.x's pending-confirm path
is live and the INCLUDERC for `/etc/procmail-pending.rc` is already
present in every user's `~/.procmailrc`. If 1.2.x ships in a degraded
form (e.g. extension shipped, procmail clear-on-receive deferred), Phase
2 below adds its own INCLUDERC line and the system one is added by
whichever of the two ships first; the two lines are idempotent and
order-independent at the include level (the file-content ordering is
what matters and is handled by `procmailrc`, not by the includes).

## Data model

The wire shape, extending the [design handoff's Rule
type](design_handoff_mail_rules/README.md#data-model) with the `reply`
fields the handoff omitted:

```ts
type Field = 'from' | 'to' | 'cc' | 'subject' | 'body';
type Action = 'move' | 'copy' | 'delete' | 'archive' | 'none';

interface Condition {
  field: Field;
  value: string;       // substring; only operator is contains
}

interface Rule {
  id: string;                  // server-assigned; "r-" + 12 hex chars
  name: string;                // <= 100 chars
  enabled: boolean;
  conditions: Condition[];     // ANDed; empty matches everything
  action: Action;              // mutually-exclusive destination
  moveFolder: string;          // used when action === 'move'
  copyFolders: string[];       // used when action === 'copy'
  flag: boolean;               // independent; n/a when action === 'delete'
  markRead: boolean;           // independent; n/a when action === 'delete'
  forward: string[];           // 0+ email addresses; n/a when action === 'delete'
  reply: boolean;              // independent; n/a when action === 'delete'
  replyBody: string;           // used when reply === true; <= 4000 chars
  continueToNext: boolean;     // spill-through; n/a when action === 'delete'
}

interface RuleSet {
  user: string;                // Cognito username
  rules: Rule[];               // ordered; index = precedence
  version: number;             // optimistic concurrency
  updatedAt: string;           // ISO 8601
}
```

Notes on the additions:

- `action: 'none'` is new and matches the design-brief's empty selection
  case (zero destinations chosen). Adding an explicit enum value is
  cleaner than reusing `null` and is forward-compatible with future
  destination actions. The four design-brief values (`move`, `copy`,
  `delete`, `archive`) are unchanged. The React editor's segmented
  control surfaces only the four; `'none'` is the implicit value when
  no destination pill is active.
- `reply` and `replyBody` model the Reply action. See
  [Reply action](#reply-action) below for the full treatment.
- `version` carries optimistic concurrency for the rule set as a whole;
  the API rejects writes with a stale version. Avoids two devices
  silently overwriting each other.

### Storage

A new DynamoDB table, `cabal-user-rules`:

| Attribute   | Type | Notes                                       |
| ----------- | ---- | ------------------------------------------- |
| `user`      | S    | Hash key. Cognito username.                 |
| `rules`     | S    | JSON-encoded `Rule[]`. Bounded length.      |
| `version`   | N    | Monotonic; increments on every write.       |
| `updatedAt` | S    | ISO 8601. Telemetry-only.                   |

One row per user, atomic writes. The rule set is small (max 100 rules at
~1 KB each = 100 KB; well inside DynamoDB's 400 KB row limit). The
single-row design keeps reads cheap (one `GetItem` on app load) and
writes atomic (no fan-in race when reordering). The trade-off is that
all writes are full-row replacements -- acceptable at this size and
write rate.

Table defined alongside the existing tables in
[`terraform/infra/modules/table/`](../../terraform/infra/modules/table/main.tf):
encryption-at-rest on, point-in-time recovery on, pay-per-request.

### Rule ordering

Precedence is the position of a rule in the `rules` array. There is no
separate ordinal column, no per-rule rank, and no predecessor pointer.
The whole set is one JSON-encoded array in one DynamoDB row.

This is deliberate, and it dissolves the reordering-cost problem rather
than solving it. The concern -- "if every rule carries an integer
ordinal, inserting or moving one forces a renumber of everything after
the insertion point" -- is real, but it only arises in a *row-per-rule*
design where order has to be reconstructed by sorting on a stored key.
The patterns that fix it there (predecessor/linked-list pointers,
fractional or lexicographic ranking a la
[a Figma-style fractional index](https://www.figma.com/blog/realtime-editing-of-ordered-sequences/))
all exist to avoid rewriting N rows on a reorder.

We have one row. Reordering -- whether a drag-drop, an insert, or a
delete -- is the client splicing its local array and issuing a single
`PUT /rules` with the full array in its new order. One write, O(1) in
the number of rules, regardless of where the change lands. No
renumbering cascade because there are no numbers to renumber: array
index 0 runs first, index 1 next, and so on. The compiler emits
recipes into `/etc/procmail-user/<user>.rc` in exactly array order.

The cost we pay instead is that every edit rewrites the whole array.
At the bounded size here (<= 100 rules, ~100 KB) that is a single
small DynamoDB write, cheaper than the multi-row transaction a
row-per-rule reorder would need. Optimistic concurrency (`version`)
guards the one race this design has: two devices splicing different
local copies. The second writer's stale `version` loses and is told
to reload, rather than interleaving two orderings into nonsense.

If the rule set ever outgrew a single row (it won't at these limits),
the migration would be to a row-per-rule table with fractional-index
ranks -- but that is a bridge for a scale this feature does not reach.

### BCC is not offered

The design brief lists six condition fields; this plan ships five.
BCC is dropped, not deferred.

A blind-carbon-copy recipient is, by definition, removed from the
message headers before the message is transmitted -- that is what
makes it blind. By the time a message reaches the IMAP tier's procmail
pipeline, there is no `Bcc:` header to match against (the rare
exception, a sender who leaves a `Bcc:` header in place, is a
misconfiguration we should not build a feature around). A "BCC
contains" condition would therefore match essentially nothing, every
time, silently.

Shipping a control that never fires teaches the user the wrong mental
model of how their mail is handled and erodes trust in the rules that
*do* work. So BCC is absent from the field picker entirely -- not
present-but-disabled, not present-with-a-warning. The five remaining
fields (`from`, `to`, `cc`, `subject`, `body`) all map to content that
is reliably present at delivery time. This deviates from the brief by
omission; flagged here and in [the CHANGELOG](#54-changelog) so the
deviation is explicit rather than silent.

### Reply action

The design brief lists Reply as one of the actions but the prototype's
data model omits it. Adding it here:

- **Semantics.** Reply is an independent extra, like Flag / Mark read /
  Forward. It is NOT in the mutually-exclusive destination set. A rule
  can `move` AND `reply`, or just `reply`, or `archive` AND `reply`, etc.
- **Body.** Plain text only in v1. The compose pipeline already handles
  rich text for outbound mail, but vacation replies are by convention
  plain text (no embedded images, no remote loads, no tracking pixels),
  and keeping the body plain text closes off a meaningful class of
  abuse where a hostile user could craft a rule whose "auto-reply"
  pulls a remote image and turns the rule into a tracker beacon. Length
  capped at 4000 chars.
- **Headers.** The auto-reply uses `formail -rt` to assemble a
  reply-formatted header set (`In-Reply-To`, `References`, swapped
  From/To). The reply's From is **the address the original message was
  delivered to** -- the recipient address (the matched `To`/envelope
  recipient), not the operator-owned `mail-admin.<first-mail-domain>`
  address. This keeps the reply in the same thread on the sender's
  side and means the sender sees a reply from the address they wrote
  to, which is what a vacation reply is for. The trade-off is that
  replying confirms the address is live to whoever mailed it (relevant
  because Cabalmail addresses are often vendor-burned); the user has
  already accepted that by enabling auto-reply on a rule that matches
  mail to that address. The compiler resolves the recipient address
  from the delivered envelope/`To` and uses it verbatim as the From;
  it does not synthesize an address. The reply's Subject is
  `Re: <original subject>` if not already prefixed. An
  `Auto-Submitted: auto-replied` header is added to mark the message
  as a vacation reply per RFC 3834.
- **Loop prevention.** Procmail's standard `vacation.cache` mechanism
  (or `formail -D` against a per-user dbm cache) suppresses repeated
  replies to the same sender within a configurable window
  (default 7 days). This is the cheap, well-understood guard; the
  vacation cache lives in the user's home directory at
  `~/.cabal-rules-reply-cache.db`.
- **Bounce suppression.** Auto-replies to mailer-daemons and
  list servers cause reply storms. The compiler emits a header-based
  guard ahead of every reply rule: skip if
  `Auto-Submitted: !no`, `Precedence: bulk|junk|list`,
  `List-Id:`, `X-Mailer-Daemon:`, or empty `From:`. This guard is not
  user-controlled; it is baked into every compiled reply recipe.
- **Per-message rate cap.** Reply caps at 100 replies per user per 24h
  (hard, enforced by an additional procmail counter file). A user
  who hits the cap stops replying until the window rolls over; a
  warning is surfaced in the UI next session.

The React editor adds a Reply pill to the auxiliary-action grid
alongside Flag / Mark as read / Forward. When Reply is on, a
multi-line text input (similar in shape to the Forward chip input
but a single editable region) appears below the aux grid for the
body. Apple clients render the same as a native multi-line text
field in the rule editor.

### Validation

| Field             | Rule                                                              |
| ----------------- | ----------------------------------------------------------------- |
| `name`            | 1-100 chars; printable Unicode; whitespace trimmed.               |
| `conditions[].value` | 1-500 chars; printable Unicode; rejected if it contains \0.   |
| `moveFolder`      | Must match a folder in the user's `list_folders` response.        |
| `copyFolders[]`   | Each must match a folder in the user's `list_folders` response.   |
| `forward[]`       | Each must match `^[^\s@]+@[^\s@]+\.[^\s@]+$`. Invalid chips are stored client-side per the design but stripped at PUT time -- see Phase 1. |
| `replyBody`       | 1-4000 chars when `reply === true`. Plain text only.              |
| `rules.length`    | <= 100 per user.                                                  |

Server-side validation rejects any rule failing the schema with 400 and
a structured error indicating which field on which rule failed. The
client surfaces the error inline next to the offending field.

### No folder auto-creation

Folder targets (`moveFolder`, `copyFolders[]`, and the implicit Archive
target of the `archive` action) are always chosen by the user from the
list of folders that already exist. The rule editors populate their
folder pickers from the user's live `list_folders` response and offer
no free-text folder entry and no "create folder" affordance inside the
rule editor. A user who wants a new destination creates it first via
the existing Folders surface, then picks it in the rule.

The system never creates a folder on the user's behalf -- not at
rule-save time, not from a quick-start template, and emphatically not
at **rule-execution (delivery) time**. If a rule names a folder that no
longer exists when the compiler runs (the user deleted it after writing
the rule), the compiler skips that rule with reason `folder_not_found`,
logs it, and moves on; the message delivers to INBOX and the user's
other rules still apply. We do not resurrect a deleted folder, and we
do not silently divert mail into a folder the user did not deliberately
keep. Auto-creating folders during delivery would be action at a
distance -- mail appearing in folders the user never made -- and is the
kind of surprise this feature is built to avoid.

The one consequence worth calling out: the `archive` action depends on
an Archive folder existing. It is not special-cased. If the user has no
Archive folder, an `archive` rule is skipped exactly like a `move` to a
missing folder. The clients guide the user toward creating an Archive
folder (via the normal Folders UI) when they pick the Archive action
and none exists -- a user-initiated create through the existing folder
API, not an implicit one.

## Architecture

```
+----------------+        PUT /rules            +-------------------+
| React / Apple  | ---------------------------> | cabal-user-rules  |
|   editor       |                               |   (DynamoDB)      |
+----------------+                               +-------------------+
                                                          |
                                            SNS publish    |
                                            (rules topic)  |
                                                          v
                                                  +---------------+
                                                  |  imap tier    |
                                                  |  SQS subscriber|
                                                  +---------------+
                                                          |
                                          reconfigure.sh    |
                                          on SQS message    |
                                                          v
                                            +---------------------------+
                                            | compile-user-rules.py     |
                                            |   - scan cabal-user-rules |
                                            |   - per user, emit        |
                                            |     /etc/procmail-user/    |
                                            |       <user>.rc            |
                                            +---------------------------+
                                                          |
                                                          v
                                                +---------------------+
                                                | procmail per delivery|
                                                | reads:               |
                                                | 1. /etc/procmail-    |
                                                |    pending.rc        |
                                                | 2. /etc/procmail-    |
                                                |    user/<user>.rc    |
                                                | 3. DEFAULT Maildir   |
                                                +---------------------+
```

### Storage layout in the IMAP container

Container-local `/etc/procmail-user/`, one file per user:

```
/etc/procmail-user/
  alice.rc
  bob.rc
  carol.rc
  ...
```

Each file is regenerated atomically on every reconfigure (write to
`.tmp`, `fsync`, `rename`). Procmail reads it at message-delivery time
via the user's `~/.procmailrc`:

```
INCLUDERC=/etc/procmail-pending.rc          # 1.2.x, system-owned
INCLUDERC=/etc/procmail-user/$LOGNAME.rc    # 1.3.x, this plan
```

(`$LOGNAME` is set by procmail to the receiving user. The compiler
uses the same Cognito username everywhere -- the `cabal-user-rules.user`
field matches the OS account name created by
[`sync-users.sh`](../../docker/shared/sync-users.sh).)

A user with no rules gets an empty file. Procmail reads the empty
include and falls through. Cost: a few syscalls per delivery.

### Reconfigure path

A new SNS topic, `cabal-user-rules-reconfigure`, mirrors the existing
address-reconfigure pattern. Writers (the `set_rules` Lambda) publish
on every successful PUT. The IMAP tier's existing SQS subscriber (one
queue per container, fanout from the topic) receives the message and
calls `reconfigure.sh`, which is extended to also invoke
`compile-user-rules.py`.

Why a new topic instead of reusing the address topic: the address topic
already triggers a full DynamoDB scan + regeneration of every sendmail
map file. Rule writes happen at user-typing cadence (debounced 300ms)
and would amplify into expensive rebuild loops if they piggybacked on
the address topic. Separating the two lets each pipeline regenerate
only what it owns.

Periodic fallback in [`reconfigure.sh`](../../docker/shared/reconfigure.sh)
already covers lost SNS messages (15-min periodic regeneration); the
rule compiler runs on the same fallback cadence.

### compile-user-rules.py (the compiler)

The compiler is the single most security-critical piece in this plan.
It is the *only* component that emits procmail syntax derived from
user input. Everything before it can be loose; the compiler must be
defended in depth.

Inputs:
- A DynamoDB scan of `cabal-user-rules`.
- A snapshot of each user's folder list (fetched once per
  reconfigure -- one IMAP `LIST` per user, cached for the duration of
  the run).
- The compiled output of `compile-user-rules.py --self-test` (see
  below) is asserted at container start-up.

Outputs:
- One file per user at `/etc/procmail-user/<user>.rc`, mode `0644`,
  owned by `root`, world-readable. (Procmail runs setuid-stripped as
  the recipient user; world-read is correct.)
- A summary log line per user (rule count, skipped rules, total
  bytes).
- A CloudWatch EMF metric per user with success/skip counts (per
  reconfigure cycle, aggregated).

Per-rule compilation:

1. **Schema validation.** Re-validate every field against the same
   schema the API enforced at write time. A rule failing schema is
   skipped with a logged warning and continues to the next rule. (The
   API should have caught this; defense in depth.)
2. **Folder verification.** Re-verify `moveFolder` and `copyFolders[]`
   against the live IMAP folder list. A rule referencing a deleted
   folder is skipped. (Users will create rules referencing folders
   and later delete the folder; we don't want to surprise them with
   silent moves to a reincarnated folder.)
3. **Header-name canonicalization.** Map `Field` to the procmail
   header anchor:
   - `from` -> `^From:`
   - `to` -> `^To:`
   - `cc` -> `^Cc:`
   - `subject` -> `^Subject:`
   - `body` -> body match (procmail `* B ?? ...`)

   There is no `bcc` mapping; BCC is not a supported field (see
   [BCC is not offered](#bcc-is-not-offered)). A stored rule that
   somehow carries a `bcc` condition (hand-crafted PUT bypassing the
   client) fails schema re-validation in step 1 and is skipped.
4. **Value escaping.** Each condition's `value` is wrapped in
   `\Q...\E`-equivalent procmail escapes. Procmail's matcher is
   regex; we want literal substring. Concretely: build the matcher
   as `.*<escaped value>.*` where `<escaped value>` has every regex
   metacharacter (`.^$*+?()[]{}|\\`) backslash-escaped. The output
   is unit-tested against an injection corpus (see Phase 2).
5. **Case-insensitive substring.** Procmail's `* ` recipes are
   case-insensitive by default unless `D` is set -- good, that's
   what the design specifies. We do NOT enable the case-sensitive
   `D` flag.
6. **Destination action emission.** Compile to the standard
   procmail patterns:
   - `move`: `:0 :` recipe with `<escaped folder>/` as the action
     line. Folder gets the same escape treatment as values, then is
     verified against the IMAP list.
   - `copy`: a `:0 c:` recipe per copy target plus a continuation
     marker so the rule keeps running.
   - `delete`: `:0` with `/dev/null` as the action.
   - `archive`: `:0 :` to the user's Archive folder, resolved against
     the live IMAP folder list like any other folder target. The
     compiler never creates the Archive folder. If the user has no
     Archive folder, the rule is skipped with reason
     `folder_not_found`, exactly as a `move` to a missing folder is.
     (See [No folder auto-creation](#no-folder-auto-creation).)
   - `none`: no destination recipe; auxiliary actions still run.
7. **Auxiliary action emission.**
   - `flag`: `formail`-based header rewrite that adds an IMAP
     `\Flagged` keyword. Procmail can write Maildir messages with
     the `F` info-flag suffix directly, the cleaner path; see
     [Maildir info flags](https://cr.yp.to/proto/maildir.html).
   - `markRead`: same approach, `S` info-flag.
   - `forward`: per-address `! <addr>` line, with `<addr>` validated
     against the email regex AND constrained to a length cap (320
     chars per RFC 5321 limit).
   - `reply`: a guarded `formail -rt` recipe (see
     [Reply action](#reply-action)) plus the vacation cache and
     bounce-suppression headers.
8. **Spill-through wrapping.** Procmail's default is to stop after
   the first matching delivering recipe. To express "continue to
   next rule":
   - Non-spill rules compile to a regular `:0 :` -- procmail stops
     after delivery.
   - Spill rules compile to a `:0 c:` (copy) for the destination
     action, plus the auxiliary actions, so procmail keeps reading
     subsequent recipes. This is the standard procmail idiom and is
     exactly what the design's "Continue to next rule" toggle means.
9. **Per-rule wrapping with a guard.** Each rule's recipes are
   wrapped in a brace block guarded by an enable check at compile
   time. Disabled rules are simply not emitted. The compiled file
   thus contains only enabled rules, in order, in the user's chosen
   precedence.

Compiler failure modes:
- **A single rule fails to compile.** Skip the rule, log a warning
  with `(user, rule_id, reason)`, continue to the next rule. The
  user's other rules still apply.
- **The entire user's rule set fails (e.g. DynamoDB returns
  malformed JSON).** Emit an empty file for that user. Log an
  error. The user's mail still delivers to INBOX.
- **The compiler itself crashes mid-run.** The reconfigure loop's
  supervisord wrapper restarts it. Until then, the previous
  compiled files (last good state) remain in place; deliveries
  continue to use the prior rule set. This is the safe default --
  better stale than broken.

Compiler self-test:
- `compile-user-rules.py --self-test` runs at container start-up
  before the supervisord stanza for sendmail comes up. It compiles
  a baked-in fixture rule set (covers every action and field) and
  asserts the output is byte-for-byte identical to a checked-in
  golden file. If self-test fails, the container exits with a
  non-zero code and ECS replaces the task. This catches an
  inadvertent compiler regression before the new code touches any
  user's mail.

### What the procmail-pending include and user includes share

Both live under `/etc/`, both regenerated on reconfigure, both
referenced from `~/.procmailrc`, both use atomic temp-file-then-
rename. The pending include is one file system-wide
(`/etc/procmail-pending.rc`); the user include is one file per user
(`/etc/procmail-user/<user>.rc`). The two pipelines do not interact:
they have separate SNS topics, separate DynamoDB tables, separate
compilers. The IMAP container regenerates both on the same reconfigure
event when either fires, since the reconfigure loop is shared.

### Procmail log growth and rotation

Yes -- we need to handle this, and it is not handled today.

[`docker/imap/configs/procmailrc`](../../docker/imap/configs/procmailrc)
sets `LOGFILE=$HOME/.procmail/log` -- a per-user log file that lives on
the EFS mailstore. Procmail appends to it on every delivery and has no
built-in rotation or size bound. Today, with a single spam rule, the
file grows slowly and nobody has noticed. Once users have rules that
fire (and especially once the compiler writes a per-rule `[r-xxxxxx]`
prefix on each decision for "why did my rule fire" debugging), the log
grows faster, per user, forever, on the most expensive storage in the
system. That is a real leak, so this plan bounds it rather than
inheriting the unbounded behavior.

Two parts:

1. **Keep procmail's own logging modest.** We do NOT set `VERBOSE=on`.
   The default log line per delivery plus the compiler's one-token
   `[r-xxxxxx]` rule marker is enough to answer "which rule fired"
   without dumping the full recipe trace. The structured,
   operator-facing logs (compile results, skip reasons, metrics) go to
   CloudWatch via the compiler's stdout and the container log driver --
   not into the per-user EFS log.

2. **Rotate the per-user logs on the existing reconfigure tick.** The
   reconfigure loop already wakes on a 15-minute fallback cadence
   ([`reconfigure.sh`](../../docker/shared/reconfigure.sh)). Add a
   size-based `copytruncate` rotation step to that loop (a small
   logrotate invocation, or a direct `copytruncate`-style truncate when
   a log exceeds a cap, e.g. 5 MB; keep the current file plus one prior
   `.1`). `copytruncate` is the right mode because procmail holds the
   file open and appends -- truncating in place avoids the
   open-fd-points-at-a-deleted-inode problem a rename-based rotation
   would create. No new cron or timer infrastructure; it rides the
   loop that already runs.

This is container-local operational hygiene; it does not touch the rule
data model or the API. It is called out in Phase 2 and verified there.

## Security model

The defining risk of this feature is procmail itself. Procmail is a
small interpreted language with the ability to pipe messages to
arbitrary shell commands, deliver to arbitrary file paths, and rewrite
headers. A user-controlled string injected into a procmail recipe is a
remote code execution surface. The whole point of the "safe UI" framing
is to ensure user input never reaches procmail syntax unescaped.

### The threat: procmail injection

The attack surface is anywhere user-controlled text becomes part of a
procmail recipe. With the data model above, four such places exist:

1. Condition `value` -- substring to match in a header or body.
2. `moveFolder` and `copyFolders[]` -- folder names.
3. `forward[]` -- forward addresses.
4. `replyBody` -- the auto-reply body.

For each, we apply two layers of defense:

**Layer 1: schema validation at write time.** The API enforces:
- Allowed character classes (printable Unicode for values and replies;
  the existing IMAP folder character set for folders; the email regex
  for addresses).
- Length caps (see [Validation](#validation)).
- Rejection of NUL, control characters except `\n` in `replyBody`,
  ANSI escapes, and characters known to be procmail-meaningful in
  contexts where they shouldn't appear (`|`, `>`, backticks anywhere
  in folder names; CR/LF in single-line fields).

**Layer 2: escaping at compile time.** The compiler treats every
user-controlled string as untrusted regardless of whether the API
validated it. Concretely:

- Condition values are escaped per regex (every regex metacharacter
  backslash-escaped) and wrapped in `.*...*` so they remain
  substring-anchored.
- Folder names are quoted in a way that procmail's parser treats as a
  literal path component, and the path is constrained to live under
  the user's `$HOME/Maildir/` (no `..`, no leading `/`, no embedded
  `|` or `>` regardless of what the validation said).
- Forward addresses become arguments to `! <addr>` after a final regex
  recheck. If a re-check fails, the recipe is skipped, NOT mangled.
- The reply body is base64-encoded by the compiler and emitted as a
  `formail`-piped heredoc that decodes at runtime. The body never
  appears in procmail syntax in plaintext; what appears is a fixed
  procmail recipe shape plus an opaque base64 blob.

Both layers are tested with an injection corpus (Phase 2). The corpus
includes the classics -- `; rm -rf /`, `$(...)`, backticks, embedded
newlines, NUL, `|/bin/sh`, `> /etc/passwd`, regex anchors, procmail
condition-class characters (`H`, `B`, `D`, `H ?? ^`, etc.), and the
canonical procmailrc-injection examples from public security
literature.

### Sandbox the recipient user

Procmail runs as the recipient user. The recipient user is created by
[`sync-users.sh`](../../docker/shared/sync-users.sh) with a constant UID
(`custom:osid` from Cognito), no shell login (`useradd -m` defaults are
fine), and no sudo. The user's writable surface is their `$HOME` and
`/tmp`. Even if injection succeeded, the blast radius is the user's own
mailbox, not the container or other users' mailboxes.

We additionally:

- Pin the procmail executable to the system-supplied binary
  (`/usr/bin/procmail`) and refuse to run if the binary is replaced.
- Set `SHELL=/usr/bin/false` in the system `procmailrc` so any `|`
  pipe a malformed rule produces fails to invoke a shell. The handful
  of legitimate pipes (`formail`, the auto-reply assembly) are emitted
  by the compiler with absolute paths and known-safe argument shapes.
- Refuse to compile any rule whose action would land outside the user's
  Maildir tree. The compiler resolves the configured target folder
  against the user's IMAP folder list and rejects any compiled path
  that doesn't normalize back into `$HOME/Maildir/...`.

### Rate limits

- Per-user rule count cap: 100 rules.
- Per-rule condition cap: 10 conditions.
- Per-rule forward cap: 10 addresses.
- Per-rule reply body cap: 4000 chars.
- Per-user reply rate cap: 100 replies / 24h, enforced at delivery
  time by a counter file in `~/.cabal-rules-reply-cache.db`.
- Per-sender vacation suppression: 7-day suppression on repeated replies
  to the same envelope sender.
- Per-message forward count, summed across all rules that fire on a
  single message: 10 (hard cap inside the compiler -- if a single
  message would trigger more than 10 forwards via spill-through, the
  surplus is dropped silently for that delivery).

### Audit

Every PUT writes to `cabal-user-rules-audit` (a new auditing table,
ttl-pruned at 90 days): `{user, ts, version, diff}`. The diff is a
JSON Patch of the change. Used for:
- User-side "what did I change yesterday" rollback (out of scope for
  v1, but the data is captured for the future).
- Operator-side incident response: a rule was deployed that caused a
  mail loop, we want to know who set it and what it said.

### Logging

The compiler emits structured logs per user:
- `compile_ok` with `(user, rule_count, byte_count)`.
- `compile_skip_rule` with `(user, rule_id, reason)` -- includes
  schema validation failures, folder-not-found, escaping rejections.
- `compile_skip_user` with `(user, reason)` -- includes catastrophic
  decode failures.

These flow to CloudWatch via the existing container log driver and
into the EMF metric set for alarming.

Procmail's own log file (`~/.procmail/log` per
[`procmailrc`](../../docker/imap/configs/procmailrc) line 3) carries
per-delivery decisions. The compiler emits a structured prefix per
rule (`[r-xxxxxx]`) so operators can see which rule fired for which
message.

## Phase 1 -- Backend storage and API

Goal: the rule set has a place to live, can be read and written by
authenticated users, and round-trips end-to-end with no IMAP-tier
involvement yet.

### 1.1 Terraform: cabal-user-rules table

A new `aws_dynamodb_table` "user_rules" in
[`terraform/infra/modules/table/main.tf`](../../terraform/infra/modules/table/main.tf),
mirroring the `user_preferences` shape: hash key `user`, encryption on,
point-in-time recovery on, pay-per-request. Outputs the ARN.

A new `aws_dynamodb_table` "user_rules_audit" with hash key `user`,
range key `ts` (number, epoch millis), and a `time_to_live` attribute
on `expiresAt` for 90-day pruning.

### 1.2 Terraform: SNS topic

A new `aws_sns_topic.user_rules_reconfigure` in
[`terraform/infra/modules/app/`](../../terraform/infra/modules/app/),
with a corresponding subscription per IMAP container's SQS queue. The
existing
[`terraform/infra/modules/ecs/`](../../terraform/infra/modules/ecs/)
already wires SNS->SQS for the address topic; mirror the pattern.

### 1.3 Lambda: get_rules

A new `lambda/api/get_rules/function.py`:

```python
def handler(event, _context):
    user = event['requestContext']['authorizer']['claims']['cognito:username']
    response = table.get_item(Key={'user': user})
    item = response.get('Item', {})
    return {
        'statusCode': 200,
        'body': json.dumps({
            'rules': json.loads(item.get('rules', '[]')),
            'version': int(item.get('version', 0)),
            'updatedAt': item.get('updatedAt', ''),
        })
    }
```

GET; mirrors the
[`get_preferences`](../../lambda/api/get_preferences/function.py)
pattern.

### 1.4 Lambda: set_rules

A new `lambda/api/set_rules/function.py`. PUT. Behavior:
- Reads `{rules: Rule[], expectedVersion: number}` from the request.
- Validates against the schema in
  [Validation](#validation). Returns 400 with `{errors: [...]}` on
  failure.
- Performs an UpdateItem with a `ConditionExpression: version = :v`
  to enforce optimistic concurrency. Returns 409 on mismatch.
- On success: bumps `version`, sets `updatedAt`, publishes to the
  rules SNS topic, writes a row to `cabal-user-rules-audit` with the
  JSON Patch diff against the prior version.
- Returns the new version in the response body.

The forward-address validation runs server-side: invalid chips
(allowed in the editor for typing reasons per the design brief) are
stripped at PUT time. The response surfaces stripped chips so the UI
can show them.

### 1.5 API Gateway wiring

Add `get_rules` and `set_rules` to
[`terraform/infra/modules/app/locals.tf`](../../terraform/infra/modules/app/locals.tf)
in the same shape as `get_preferences` / `set_preferences`. No
caching.

### 1.6 IAM

The `set_rules` Lambda needs `dynamodb:PutItem` /
`dynamodb:UpdateItem` on `cabal-user-rules`, `dynamodb:PutItem` on
`cabal-user-rules-audit`, and `sns:Publish` on the rules topic. The
`get_rules` Lambda needs `dynamodb:GetItem` on `cabal-user-rules`.

### 1.7 React API client

Add `getRules()` / `setRules(rules, expectedVersion)` to
[`react/admin/src/ApiClient.js`](../../react/admin/src/ApiClient.js).

### 1.8 Apple API client

Add `listRules()` / `setRules(_:expectedVersion:)` to
[`apple/CabalmailKit/Sources/CabalmailKit/API/ApiClient.swift`](../../apple/CabalmailKit/Sources/CabalmailKit/API/ApiClient.swift),
matching the React shape. Implement in
[`URLSessionApiClient.swift`](../../apple/CabalmailKit/Sources/CabalmailKit/API/URLSessionApiClient.swift).

### Phase 1 verification

1. `terraform plan` against the new resources is clean; checkov,
   tflint, tfsec pass.
2. Pylint passes on the new Lambdas; the existing CI matrix in
   `.github/workflows/app.yml` builds and deploys them.
3. Manual: curl-with-JWT against `GET /rules` on a user with no rules
   returns `{rules: [], version: 0, updatedAt: ''}`. PUT a small rule
   set; GET reflects it.
4. Manual: PUT with `expectedVersion: 99` against a freshly-versioned
   row returns 409.
5. Manual: PUT a rule with `replyBody: "x" * 5000` returns 400 with
   a per-field error.
6. Manual: PUT a rule with `forward: ["valid@example.com",
   "not-an-email"]` returns 200, the stored row has only the valid
   address, and the response surfaces the stripped invalid one.
7. Manual: PUT a rule with a `moveFolder` that doesn't exist in the
   user's IMAP folder list. The API accepts it (folder existence is
   verified at compile time, not write time, because the user might
   create the folder right after); the response includes a
   `warnings` field naming the unverified folder. The React UI
   surfaces the warning inline.
8. Manual: confirm SNS publishes are observable in CloudWatch on
   every successful PUT.

## Phase 2 -- Procmail compiler and IMAP-tier integration

Goal: the rules a user writes via Phase 1 actually shape mail delivery.

### 2.1 The compiler script

Add `docker/shared/compile-user-rules.py` -- a Python 3 script invoked
from `reconfigure.sh`. Modeled on
[`generate-config.sh`](../../docker/shared/generate-config.sh)'s
embedded Python:
- Scan `cabal-user-rules`.
- For each user, fetch their IMAP folder list (cached for the run).
- For each rule, run the compilation pipeline described in
  [compile-user-rules.py](#compile-user-rulespy-the-compiler).
- Write `/etc/procmail-user/<user>.rc` atomically.
- Emit per-user log lines and EMF metrics.

A companion `docker/shared/compile-user-rules-selftest.py` runs the
self-test described above.

### 2.2 docker/shared changes

- [`docker/shared/reconfigure.sh`](../../docker/shared/reconfigure.sh):
  add `compile-user-rules.py` to the IMAP-tier branch of
  `regenerate()`. Subscribe to the new SNS topic on top of the
  existing one (single SQS subscriber, fan-in).
- [`docker/shared/sync-users.sh`](../../docker/shared/sync-users.sh):
  after the existing pending-include line, add:
  ```sh
  grep -q '/etc/procmail-user/' "/home/${username}/.procmailrc" \
    || echo 'INCLUDERC=/etc/procmail-user/$LOGNAME.rc' \
      >> "/home/${username}/.procmailrc"
  ```
  Idempotent. Runs on every container start; correct on first run
  AND on subsequent runs.
- [`docker/imap/configs/procmailrc`](../../docker/imap/configs/procmailrc):
  add `SHELL=/usr/bin/false` near the top, ahead of any INCLUDERC,
  per [Sandbox the recipient user](#sandbox-the-recipient-user).
  Leave `VERBOSE` unset (default off) per
  [Procmail log growth and rotation](#procmail-log-growth-and-rotation).
- New file `docker/imap/configs/procmail-user.rc.empty` -- an empty
  fixture procmail include used as the initial state for a user with
  no rules. Saves the compiler from having to special-case the
  empty-set on first run.
- [`docker/shared/reconfigure.sh`](../../docker/shared/reconfigure.sh)
  (log rotation): add a `copytruncate`-style rotation step for each
  user's `~/.procmail/log` to the IMAP-tier branch of the reconfigure
  loop, bounding per-user logs at ~5 MB with one prior rotation kept,
  per [Procmail log growth and rotation](#procmail-log-growth-and-rotation).
  Either a bundled `logrotate` config invoked with
  `--state /var/lib/cabal/procmail-logrotate.state`, or a direct
  size-checked truncate in shell -- the choice is an implementation
  detail; `copytruncate` semantics are the requirement (procmail holds
  the file open, so the active inode must survive rotation).

### 2.3 Dockerfile changes

`docker/imap/Dockerfile`:
- Bake `compile-user-rules.py` and its self-test into
  `/usr/local/bin/`.
- Bake `confirm-cabal-address` from 1.2.x in the same way (already
  done by 1.2.x; this is just a note that the two scripts live
  side-by-side).
- Add a `RUN /usr/local/bin/compile-user-rules-selftest.py` to the
  build so the build fails if the compiler regresses against the
  golden fixture. This is in addition to the runtime self-test.

### 2.4 IAM additions

The IMAP task role gains `dynamodb:Scan` on `cabal-user-rules` (it
already has `Scan` on `cabal-addresses` for `generate-config.sh`,
so this is one more action on one more table).

### 2.5 Test corpus

`docker/shared/test/compile-user-rules/`:
- A baseline corpus of ~50 rules covering every action, every
  field, spill-through on and off, every aux-action combination, and
  empty conditions.
- An injection corpus of ~30 hostile-input rules, each asserting
  that the compiler either rejects the rule (the strict path) or
  produces output that escapes the input (the safe-fall-through
  path). Tested with `pytest` in the existing Python test job.

### Phase 2 verification

Several of these steps require *external* inbound mail -- a message that
originates outside the environment under test and arrives over the
public MX path (smtp-in -> imap -> procmail), so the rule engine sees a
genuine delivery rather than a same-system loopback. The inbound test
path uses
[`scripts/test-mail-loop.py`](../../scripts/test-mail-loop.py)
**pointed from prod at stage**: run it against prod's smtp-out
submission listener, authenticated as a prod user, with `--to` set to
the stage address under test. Prod relays the message out to the public
internet; it re-enters at stage's smtp-in via DNS/MX, which is exactly
the external-arrival path. From stage's perspective the mail is
genuinely foreign -- different account, different mail domain, real MX
hop -- which is what we need to exercise the rules honestly. (The
[sinkhole test harness](../0.9.x/sinkhole-test-harness-plan.md) gives us
the complementary *outbound* assertion path for the forward and reply
steps; it does not originate inbound mail, which is why the
prod-to-stage loop is the inbound source.)

1. The compiler self-test passes in the Docker build and at
   container start-up.
2. Manual: PUT a rule that moves messages with subject containing
   "invoice" to `Receipts`. Send a test message with that subject
   from outside the system. Confirm it arrives in `Receipts`, not
   INBOX.
3. Manual: same rule but with `continueToNext: true`. Add a second
   rule that flags messages from `aws@aws.amazon.com`. Send a
   message matching both. Confirm it's flagged AND in `Receipts`.
4. Manual: a rule with `action: 'delete'`. Send a test message
   matching it. Confirm `/dev/null` consumes it AND the procmail
   log line shows the rule's `r-xxxxxx` prefix.
5. Manual: a rule with `forward: ["test@example.com"]`. Send a
   test message matching it. Confirm a copy is sent to
   `test@example.com` (or to a sinkhole in the case of the test
   harness; see
   [docs/0.9.x/sinkhole-test-harness-plan.md](../0.9.x/sinkhole-test-harness-plan.md)).
6. Manual: a rule with `reply: true, replyBody: "I'm on vacation
   until next week."`. Send a test message matching it. Confirm:
   - A reply is sent back with `Auto-Submitted: auto-replied` and
     the body matches.
   - The reply's `From` is the address the original message was
     delivered to (the recipient address), NOT
     `mail-admin.<first-mail-domain>`.
   - A second test message from the same sender within the vacation
     window does NOT trigger a reply.
   - A second test message after 7 days DOES trigger a reply.
   - A test message with `Precedence: bulk` does NOT trigger a
     reply.
   - A test message from `MAILER-DAEMON@...` does NOT trigger a
     reply.
7. Manual: PUT a rule with `moveFolder: "Receipts"` when the user
   has no `Receipts` folder. Send a matching message. Confirm the
   rule is silently skipped (compile-time folder verification),
   message delivers to INBOX, compile log shows
   `compile_skip_rule` with reason `folder_not_found`.
8. Manual: PUT a rule via curl with a hand-crafted procmail-
   injection value (`"; \\| /bin/sh -c 'echo pwned'"`). Compile.
   Verify the produced recipe in `/etc/procmail-user/<user>.rc`
   contains the value as an escaped literal, never as a pipe, and
   that a test delivery does not execute the shell.
9. Manual: confirm the 1.2.x pending-confirm path still works
   end-to-end with this version live. Create a pending address,
   confirm it via the procmail hook (1.2.x), then create a user
   rule, confirm that subsequent mail to other addresses still
   hits the rule.
10. Manual: confirm spill-through ordering across pending and user
    includes. Create a pending address. Create a user rule that
    matches mail to that pending address with
    `action: 'move', moveFolder: 'Receipts'`. Send mail to the
    address. Confirm: the pending flag clears (1.2.x ran first),
    AND the message arrives in `Receipts` (user rule ran second).
11. Manual: kill the rules-reconfigure SNS subscriber on one IMAP
    container. PUT a rule. Confirm the periodic fallback in
    `reconfigure.sh` picks up the change within the fallback
    window (15 min default).
12. Manual: an `archive` rule on a user who has NO Archive folder.
    Send a matching external message. Confirm the rule is skipped
    with `compile_skip_rule` reason `folder_not_found`, the message
    delivers to INBOX, and no Archive folder is created. Then create
    an Archive folder via the normal Folders UI, trigger a
    reconfigure, resend, and confirm the message now lands in
    Archive.
13. Manual (log rotation): inflate a test user's `~/.procmail/log`
    past the 5 MB cap (a loop of deliveries via the prod-to-stage
    path, or a synthetic append). Trigger a reconfigure tick.
    Confirm the log is rotated `copytruncate`-style: the active file
    is truncated (procmail keeps appending to the same inode, no
    delivery interruption), a `.1` prior copy exists, and older
    copies beyond the retention count are gone. Confirm `VERBOSE` is
    off in the running config (no per-recipe trace spam in the log).

## Phase 3 -- React UI

Goal: implement the design handoff. This is the bulk of the user-
facing surface and the phase the user will judge first.

### 3.1 Route and entry point

Per the [handoff route
section](design_handoff_mail_rules/README.md#route--entry-point):
add `Mail rules...` to the user menu in
[`react/admin/src/Nav/index.jsx`](../../react/admin/src/Nav/index.jsx).

Note that the current Nav has no `Preferences...` entry; the
handoff calls for placing `Mail rules...` between Accent and
Preferences. The pragmatic interpretation: place `Mail rules...`
below the accent swatches and above the view list. If a
`Preferences...` entry lands in the same release (e.g. as part of
moving theme/accent/density out of the menu and into a settings
panel), revisit.

Add a `"Rules"` case to `state.view` in
[`react/admin/src/App.jsx`](../../react/admin/src/App.jsx) and a
lazy import:
```js
const Rules = React.lazy(() => import('./Rules'));
```
Render it in `renderContent()`'s switch.

The handoff also calls for `?rule=<id>` deep links. Implement via
`URLSearchParams` against `window.location.search`; debounce-write
on selection change. Bookmark-safe and back-button-safe.

### 3.2 New Rules/ directory

`react/admin/src/Rules/`:
```
Rules/
  index.jsx              # the route component
  RulesPage.jsx          # the master/detail layout
  RulesList.jsx          # sidebar, drag-reorder, add/duplicate/delete
  RuleEditor.jsx         # detail pane: header, conditions, actions, spillthrough
  Conditions.jsx         # the rows-style conditions UI
  Actions.jsx            # the segmented-style actions UI, including Reply
  EmptyState.jsx         # the no-rules screen with templates
  HelpPopover.jsx        # the ? popover
  describe.js            # describeRule(rule) -> the one-line summary
  validate.js            # client-side validation matching the API
  templates.js           # the quick-start templates per the handoff
  Rules.css              # page-scoped styles
  Rules.test.jsx
```

Translate the design handoff's prototype files
([`rules-app.jsx`](design_handoff_mail_rules/rules-app.jsx),
[`rules-editor.jsx`](design_handoff_mail_rules/rules-editor.jsx),
[`rules-data.jsx`](design_handoff_mail_rules/rules-data.jsx),
[`rules.css`](design_handoff_mail_rules/rules.css)) into the
existing React 18 codebase. Per the handoff:
- Production setting: `rows / segmented / drag / comfortable density`.
- Discard the three "style" variants and the Tweaks panel.
- Reuse the existing `<Icon>` set from
  [`react/admin/src/assets/`](../../react/admin/src/assets/); merge
  the new icon paths (rules, help, drag, duplicate, keyboard,
  arrowRight, copy) into the central icon module.
- Reuse the existing `<UserMenu>` chrome.
- The condition field picker (`Conditions.jsx`) offers **five** fields
  -- From / To / Cc / Subject / Body -- not the six in the prototype.
  BCC is omitted (see [BCC is not offered](#bcc-is-not-offered)); drop
  the `bcc` entry from the field list the prototype's `FIELDS` array
  defines.

### 3.3 Reply UI

The aux-action row in `Actions.jsx` adds a fourth pill, Reply,
alongside Flag, Mark read, Forward. When Reply is on, a multi-line
textarea appears below the aux grid:
- `<textarea>` styled to match the design's monospace input scheme
  but with `font-family: var(--font-reader)` since this is body
  text.
- Character counter below the textarea: `<count> / 4000`.
- Same "saved locally" indicator pattern as the rest of the editor.

Per the design handoff's
[Delete locks down dependent fields](design_handoff_mail_rules/README.md#delete-locks-down-dependent-fields):
when `action === 'delete'`, the Reply pill and textarea also go
to the disabled state along with Flag / Mark read / Forward.

### 3.4 Folder picker

The handoff calls for using the existing folder data layer. Use
the same source the inbox sidebar uses
([`react/admin/src/Folders/`](../../react/admin/src/Folders/)).
Render hierarchical folders as `Parent/Child` paths in the picker
to match the IMAP wire format (`.` separator on the wire, `/` in
URLs and human-readable display).

The picker is a closed list of the user's **existing** folders. No
free-text folder entry, no inline "create folder" control in the
rule editor, per [No folder auto-creation](#no-folder-auto-creation).
A user who wants a destination that does not yet exist creates it in
the Folders view first. The one accommodation: when the user selects
the **Archive** action and has no Archive folder, the editor shows an
inline prompt offering to create one -- which calls the existing
`new_folder` API as an explicit, user-initiated action, then proceeds.
This is a user choice surfaced in the UI, not a silent auto-create at
save or delivery time.

### 3.5 Auto-save

Per the handoff: debounced `PUT /rules` (300ms after the last
mutation). The "Saved locally" label in the editor footer becomes
a real save-state indicator:
- `idle`: hidden.
- `saving`: small spinner + "Saving..." in mono.
- `saved`: small accent dot + "Saved" in mono.
- `error`: red dot + "Couldn't save. Retry." with a retry button.

Optimistic updates for toggle / reorder; rollback on error with a
toast via the existing
[`AppMessageContext`](../../react/admin/src/contexts/AppMessageContext.jsx).

### 3.6 Concurrency

Two devices editing simultaneously: the API rejects the second PUT
with 409. The React UI on the device that got 409 surfaces a banner:
"Your rules were updated from another device. Reload to see the
latest." Single button: Reload. The handoff's auto-save model
doesn't have a merge UI and shouldn't grow one in v1.

### 3.7 Empty state

Three templates per the handoff
([`TEMPLATES` in rules-data.jsx`](design_handoff_mail_rules/rules-data.jsx)):
- "File AWS receipts" -- `from contains aws.amazon.com` -> move to a
  folder the user picks.
- "Mute a newsletter" -- `from contains <user-entered>` -> archive
  + mark read.
- "Vacation reply" -- no conditions, no destination -> reply with
  a body the user fills in.

A template pre-fills conditions and action *shape*, but any
template that files mail leaves its destination folder for the user
to choose from their existing folders -- a template never names a
folder that may not exist and never creates one (see
[No folder auto-creation](#no-folder-auto-creation)). So "File AWS
receipts" lands the user in the editor with the condition and the
`move` action set, the destination empty, and the rule disabled until
they pick a folder; "Mute a newsletter" depends on an Archive folder
and surfaces the same create-an-Archive-folder prompt as the Archive
action does if none exists. (This is a small deviation from the
prototype's `TEMPLATES`, which hard-code a `Receipts` destination;
the deviation is what keeps templates honest about folder existence.)

The third template puts Reply on the user's radar from the empty
state, which is the right onboarding moment for that feature.

### 3.8 Accessibility

- Drag-reorder via mouse per the handoff, AND keyboard equivalent:
  the sidebar row in focus, `Alt-Up` / `Alt-Down` move it (mirrors
  the existing
  [`react/admin/src/Folders/`](../../react/admin/src/Folders/)
  keyboard model).
- All interactive controls have associated labels and roles.
- The destination segmented control announces the active value
  via `aria-pressed` on each pill.
- The forward chip input announces invalid chips via
  `aria-invalid` on the chip and a live region announcing the
  invalid-count summary.

### Phase 3 verification

1. The handoff's [acceptance
   checklist](design_handoff_mail_rules/README.md#acceptance-checklist)
   passes (every item).
2. Vitest unit tests cover: `describeRule` against a corpus matching
   the handoff's examples; `validate` against the schema; the
   `Reducer`/state model for add/duplicate/delete/reorder/toggle.
3. Vitest tests cover Reply specifically: the textarea, the char
   counter, the delete-disabled state, the empty-body validation.
4. Manual on desktop Chromium, Firefox, Safari: every checklist item.
5. Manual on iPhone-class viewport (375x812): single-pane swap,
   conditions stack, action segmented becomes 2x2, aux actions
   single-column, no drag handle, long-press reorder.
6. Manual on iPad-class viewport (1024x768): master/detail at full
   width.
7. Manual: two browser tabs, edit rule in one, edit in the other,
   confirm the 409 banner appears in the second.
8. Manual: deep link `/rules?rule=r-xxxxxx`; reload; the named rule
   is selected.
9. Manual: drag a rule to reorder, confirm a PUT fires within 300ms
   and the new order persists across reload.
10. Manual auto-save state machine: drop the network (browser
    devtools), edit a rule, confirm the indicator goes
    `saving -> error` with a Retry button; restore the network,
    click Retry, confirm `saved`.
11. Manual accessibility: full keyboard navigation through the
    page; VoiceOver / NVDA can describe and operate every control;
    color contrast on `--ink-quiet` against `--surface` meets WCAG
    AA.

## Phase 4 -- Apple clients

Goal: native UI parity for iOS, iPadOS, macOS, and visionOS. Same
data model, same API client, platform-idiomatic widgets.

### 4.1 Shared kit additions

In
[`apple/CabalmailKit/Sources/CabalmailKit/`](../../apple/CabalmailKit/Sources/CabalmailKit/):

`Models/Rule.swift`:
- `enum Field: String, Codable, CaseIterable { case from, to, cc,
  subject, body }` (five fields; no `bcc`, per
  [BCC is not offered](#bcc-is-not-offered)).
- `enum Action: String, Codable { case move, copy, delete, archive,
  none }`.
- `struct Condition: Codable, Hashable, Identifiable`.
- `struct Rule: Codable, Identifiable, Hashable` -- all fields per
  the data model above, including Reply.
- `struct RuleSet: Codable` -- the wire shape returned by
  `GET /rules`.

`API/ApiClient.swift`:
- `func listRules() async throws -> RuleSet`
- `func setRules(_ rules: [Rule], expectedVersion: Int) async throws
  -> RuleSet` (the result is the new version, propagated to
  optimistic-concurrency UI state).

`URLSessionApiClient.swift` -- the URLSession implementation.

`Rules/RulesValidator.swift` -- the same validation logic as the
React `validate.js`, written in Swift, so the kit's tests can
gate per-PR (alongside the React tests).

### 4.2 iOS / iPadOS / visionOS

Add `apple/Cabalmail/Views/RulesView.swift`. Surface it as a row
in the existing
[`SettingsView.swift`](../../apple/Cabalmail/Views/SettingsView.swift)
under a new section ("Rules") between Composing and Actions,
matching the existing section ordering:
```swift
Section("Rules") {
    NavigationLink("Mail rules") {
        RulesView()
    }
}
```

`RulesView` layout:
- Master/detail when the layout's size class allows
  (iPad regular-width, visionOS): a `NavigationSplitView` with
  the rules list on the left and the rule editor on the right.
- Single-pane on iPhone and iPad compact-width: a plain
  `NavigationStack` with the rules list and a push to the editor.
- Drag-reorder via `.onMove` in the rules list. Long-press in
  edit mode brings the standard iOS reorder grip.
- Toggle a rule on/off via `Toggle` in the row.
- Add / duplicate / delete via `EditButton` + swipe actions in the
  list, matching the existing
  [`FolderListView`](../../apple/Cabalmail/Views/FolderListView.swift)
  pattern.

Conditions section: `Form` with one `Section` per condition. Each
condition row: `Picker` for field (the five-case `Field` enum -- no
BCC); `TextField` for value; trailing `Button(role: .destructive)`
to remove.

Actions section: a segmented `Picker` for the mutually-exclusive
destination (Move / Copy / Archive / Delete / None). Below the
picker, a destination-specific subview:
- `move`: a folder `Picker` populated from `listFolders` -- the
  user's existing folders only; no free-text, no create affordance
  inside the picker (see
  [No folder auto-creation](#no-folder-auto-creation)).
- `copy`: a multi-select folder picker -- a navigation push to a
  list of the user's existing folders with `multipleSelection`.
- `archive`: nothing, unless the user has no Archive folder, in which
  case an inline note offers a "Create Archive folder" button that
  calls `createFolder` explicitly before proceeding.
- `delete` / `none`: nothing.

Auxiliary actions: a `Form` `Section` with `Toggle`s for Flag,
Mark read, Forward, Reply. When Forward is on, a stack of
`TextField`s with email validation and a "Add address" button.
When Reply is on, a `TextEditor` with `frame(minHeight: 120)` for
the body.

Spill-through: a single `Toggle` ("Continue to the next rule").

Save behavior: same debounce + optimistic-concurrency model as
the web. On 409: present an alert "Rules updated on another
device. Reload to see the latest." with a Reload button.

Empty state: a single screen with three template buttons and a
"Start with a blank rule" button, mirroring the web.

### 4.3 macOS

Add a `Rules` tab to
[`apple/CabalmailMac/SettingsTabsView.swift`](../../apple/CabalmailMac/SettingsTabsView.swift)
between General and Addresses:
```swift
TabView {
    SettingsView().tabItem { Label("General", systemImage: "gearshape") }
    RequiresSignIn { RulesView() }
        .tabItem { Label("Rules", systemImage: "tray.full") }
    RequiresSignIn { AddressesView() }
        .tabItem { Label("Addresses", systemImage: "at") }
    RequiresSignIn { FoldersAdminView() }
        .tabItem { Label("Folders", systemImage: "folder") }
}
```

The `RulesView` itself reuses the iOS implementation; SwiftUI
adapts the layout to the macOS chrome.

Match the macOS Settings-window conventions: the master/detail
layout, the standard padding, the standard pill segmented
controls. No custom drag-reorder UI -- SwiftUI's native one is
correct on macOS too.

### 4.4 visionOS

The shared iOS view runs unchanged on visionOS. Render in
windowed Safari-style chrome inside the host app. No 3D
affordances.

### Phase 4 verification

1. `cd apple/CabalmailKit && swift test` passes; new tests cover
   the encode/decode of `Rule`, `RuleSet`, every action and
   field permutation, and the RulesValidator against the same
   corpus the web `validate.js` uses.
2. The iOS Settings tab on iPhone simulator shows "Mail rules"
   and the tap navigates to a working editor.
3. Same on iPad simulator (regular width); the master/detail
   layout renders.
4. Same on macOS; the Settings window shows a Rules tab between
   General and Addresses; the editor works.
5. Same on visionOS simulator.
6. Round-trip parity: create rules on macOS, observe them on
   iPhone after a refresh; modify on iPhone, refresh on macOS,
   observe.
7. Conflict: edit on two devices simultaneously, confirm the
   alert lands and reload pulls the winning version.
8. Manual: drag-reorder on iPhone via EditMode reorder grip;
   confirm a PUT lands within the debounce window.

## Phase 5 -- Polish, observability, docs

### 5.1 Operator dashboard

Add a Grafana panel to the existing monitoring stack
([`terraform/infra/modules/app/grafana.tf`](../../terraform/infra/modules/app/grafana.tf)
or the relevant module):
- Per-user rule count distribution.
- Per-day rule writes.
- Compiler skip rate (count of `compile_skip_rule` per day,
  bucketed by reason).
- Auto-reply send rate per user.
- Forward send rate per user.

### 5.2 Alarms

CloudWatch alarms (added to the existing monitoring set):
- `RuleCompilerSelfTestFailures > 0` over 5 minutes.
- `RuleCompilerSkipsTotal` rate of change > 10x baseline (a
  schema change or compiler bug just shipped).
- `AutoReplySendsTotal` per user exceeding the rate cap (catches
  reply loops the cap missed; informational).
- `RulesPutLatency` p99 > 1 second.

### 5.3 User-facing docs

Add `docs/mail-rules.md` -- as-shipped operator and user
documentation, per the
[Docs convention](../../CLAUDE.md#:~:text=Docs%20convention)
(versioned subdirectories are forward-looking plans; shipped
features get top-level docs).

Contents:
- What rules can do.
- The five condition fields and how they map to real mail headers
  and bodies, plus a one-line note on why BCC is not a field.
- Each action's semantics (especially Reply's vacation-cache and
  bounce-suppression behavior, and that the reply comes From the
  address the message was sent to).
- Spill-through.
- Limits (100 rules, 100 replies / day, 7-day vacation
  suppression, etc.).
- "Why didn't my rule fire" debugging guide.
- "Where do my rules live" -- enough operator context that
  someone debugging a procmail delivery problem can find the
  right file in the container.

Link from `docs/user_manual.md` and `docs/operations.md`.

### 5.4 CHANGELOG

Add an `Unreleased` entry under 1.3.x:
- "User-defined mail rules: rule editor in the web admin app and
  in iOS / iPadOS / macOS / visionOS Settings. Rules are evaluated
  by the IMAP tier ahead of default delivery and after the 1.2.x
  pending-address confirmation pass. Conditions match From / To / Cc
  / Subject / Body (BCC is not present in delivered mail, so it is
  not offered). Actions: move, copy, archive, delete, plus
  independent flag / mark-read / forward / auto-reply."

### 5.5 Browser extension follow-up (optional)

The 1.2.x browser extension touches `cabal-addresses` via the
existing `/new` and `/revoke` endpoints; it does not need to know
about rules. No work required in this version. A future browser-
extension version might add "create a rule that auto-files mail
from this site" as a follow-on, but that's deferred.

### Phase 5 verification

1. Grafana panels render and show non-empty data after seeded
   activity.
2. Alarms trigger on synthetic failures (force a self-test
   failure, force the skip rate up).
3. `docs/mail-rules.md` reads cleanly for a first-time user.
4. CHANGELOG entry is correct as of release date.

## Migration

No migration from prior versions is required -- there are no rules
before this version. Existing users land in the empty state on first
visit. The DynamoDB table is empty until users start writing rules.

The procmailrc and sync-users.sh INCLUDERC lines are additive and
idempotent: existing users with already-patched `~/.procmailrc` from
1.2.x get the second INCLUDERC line on the next container start.
First-time-after-deploy delivery for a user that hasn't been re-
synced reads the not-yet-present `/etc/procmail-user/<user>.rc` and
falls through (procmail tolerates a missing include with `INCLUDERC`
but to be safe the compiler writes an empty file for every user at
the first run after deploy, regardless of whether they have rules).

## Out of scope for 1.3.x

- Power-user / advanced rule features (OR, regex, header
  extraction). Possible future extension; not in v1.
- Retroactive application of a new rule to existing messages.
- Per-folder rule sets.
- Outbound (send-time) rules.
- Rule sharing or admin-supplied templates beyond the three
  empty-state templates baked into the client.
- Rule set import / export (backup, share-as-file). The `GET /rules`
  JSON shape already makes this trivial on the data side; the UI
  affordance is deferred to a follow-on.
- A rule-changes audit UI for the user. (The `cabal-user-rules-audit`
  table captures the data; surfacing it is future work.)
- "Preview mode" evaluation of disabled rules. Disabled rules are
  skipped, full stop; an evaluate-without-acting preview is a
  follow-on.
- A rule-fired indicator in the inbox ("this message was filed by
  rule X"). Useful for debugging but needs a per-delivery rule-id
  store; deferred.
- An "import procmailrc" escape hatch.
- A browser-extension surface for rule creation.

## Prerequisites

- 1.2.x's procmail-pending include and its
  [Phase 3.1 backend additions](../1.2.x/browser-extension-plan.md#3-backend-additions-lambda--terraform)
  should be live before this work ships, so the ordering invariant
  in [Relation to prior work](#relation-to-prior-work) has both
  sides to enforce. (If 1.2.x slips, this work can ship first and
  hold the user-include INCLUDERC pattern open for 1.2.x's later
  addition. The two are designed to coexist regardless of which
  arrives first.)
- DynamoDB capacity headroom -- pay-per-request, no provisioned-
  capacity planning needed.
- A first-pass injection corpus (per [Phase 2](#25-test-corpus))
  drawn from public procmail-security writing.

## Settled decisions

These came up during planning and are resolved. Recorded here so the
implementation phase does not relitigate them.

1. **Reply From address: the recipient address.** Auto-replies
   originate from the address the original message was delivered to
   (the matched recipient), NOT the operator-owned
   `mail-admin.<first-mail-domain>`. Rationale: thread continuity and
   sender recognition. The user accepts the liveness-confirmation
   trade-off by enabling auto-reply on a rule that matches mail to
   that address. The compiler uses the delivered recipient address
   verbatim; it does not synthesize one. (See
   [Reply action](#reply-action).)

2. **Action precedence within a rule: endorsed.** Flag and mark-read
   are header rewrites and order-independent. Forward fires before
   reply (the forward target sees the original, not the auto-reply).
   Reply fires after forward. Spill-through, if on, runs after all
   auxiliary actions. The compiler emits recipes in this order. (See
   [Auxiliary action emission](#compile-user-rulespy-the-compiler).)

3. **Rule import / export: out of scope for v1.** Deferred to a
   follow-on; the `GET /rules` JSON already solves the data side, so
   the future work is purely the UI affordance. (See
   [Out of scope](#out-of-scope-for-13x).)

4. **Folder targets: pick from existing folders; never auto-create.**
   The rule editors offer only the user's existing folders. The
   system never creates a folder on the user's behalf -- not at save
   time, not from a template, and not at delivery/compile time. A
   rule whose folder no longer exists at compile time is skipped with
   `folder_not_found` and the message delivers to INBOX. The lone
   accommodation is a user-initiated "Create Archive folder" prompt
   when the Archive action is chosen and no Archive folder exists.
   (See [No folder auto-creation](#no-folder-auto-creation).)

5. **Per-rule "this message was filed by rule X" indicator: out of
   scope for v1.** Deferred; would need a per-delivery rule-id store.
   (See [Out of scope](#out-of-scope-for-13x).)

6. **Inbound test path: prod-to-stage via `test-mail-loop.py`.**
   Phase 2 verification originates external inbound mail by running
   [`scripts/test-mail-loop.py`](../../scripts/test-mail-loop.py)
   against prod's smtp-out, addressed to the stage address under
   test. The message leaves prod, traverses the public MX, and
   re-enters stage's smtp-in -- genuinely external from stage's
   point of view. The
   [sinkhole harness](../0.9.x/sinkhole-test-harness-plan.md) remains
   the outbound assertion path for forward/reply. (See
   [Phase 2 verification](#phase-2-verification).)

7. **Disabled rules: skipped, no preview mode.** Disabled rules are
   not emitted by the compiler and not evaluated. An
   evaluate-without-acting preview is deferred to a follow-on. (See
   [Out of scope](#out-of-scope-for-13x).)

# RSS Reader — Requirements and Decision Points

## Context

The 2.x roadmap introduces RSS as a first-class feature alongside email. The
vision is a cloud-managed feed reader where Cabalmail keeps every subscribed
feed up to date on behalf of the user, tracks per-user read/unread/favorite
state, applies user-defined filtering and organization, and pushes
notifications for selected feeds. Clients (React admin, iOS, macOS, Android)
consume a Cabalmail-native API and do not need to implement RSS/Atom parsing
themselves.

This document is the requirements pass. It states goals, non-goals, and
confirmed scope, then enumerates the decision points the operator
resolved. Each decision lists the options, trade-offs, and a recommended
starting position; the operator's inline decisions follow the
recommendations. The companion
[`rss-implementation-plan.md`](./rss-implementation-plan.md) (modeled on
the existing 1.1.x plans — see
[`bimi.md`](./../1.1.x/bimi.md),
[`push-notifications.md`](./../1.1.x/push-notifications.md)) sequences
the work.

This directory is `2.0.x` per the operator's answer to Open Q1; the
release version is 2.0. The plan splits the work across multiple patch
versions (2.0.0, 2.0.1, ...).

## Revisions after design exploration

After the operator's inline decisions were recorded, a phase-1 design
pass surfaced cost-shape findings that revised the data-layer choice and
added one new requirement. The original decisions remain inline as
historical record; **Revised decision** annotations capture the current
state. The companion
[`rss-implementation-plan.md`](./rss-implementation-plan.md) reflects
the revised state throughout.

- **Decisions 14 + Open Q2 (search + storage engine):** Aurora Postgres
  has an idle floor of ~$45/env/month that scale-to-zero doesn't help in
  practice (the fetcher tick would keep the cluster warm). Hard to
  justify at hobby scale. **DynamoDB is now the sole data store.**
  Server-side full-text search is deferred indefinitely; **per-feed FTS
  moves to Apple clients only**, backed by SQLite/FTS5. React has no
  search; cross-feed search remains out.
- **New Decision 18 (offline reading on Apple):** the local item cache
  that backs Apple-side FTS also serves offline reading. Promoted from
  implicit to a first-class requirement to match the operator's
  habitual use of offline reading on the current reader.

## Goals

- Every Cabalmail user can subscribe to RSS/Atom (and JSON Feed) feeds and
  read them across all Cabalmail clients with consistent per-user state.
- Feeds are fetched server-side on an adaptive per-feed cadence within
  operator-set bounds (no user-exposed cadence control, per D17).
- Per-feed display preferences (order, summary-vs-article default,
  reader-vs-native styling default, notifications) are persisted and synced
  across devices.
- User-defined folder hierarchy organizes feeds; read/unread/favorite state
  syncs in near real time across devices.
- Push notifications for new items use the notification path delivered in
  1.0.x (APNs) and the future Android FCM path, with per-feed/per-folder
  opt-in.
- A user can leave Cabalmail with their feed list (OPML export) and arrive
  with one (OPML import).

## Non-goals (v1)

- Non-text media as a first-class concept. Audio and video play if embedded
  in an article via the web rendering engine; podcasts as a distinct media
  type with playback queue and per-episode progress sync are deferred.
- Automated per-feed URL or content rewriting. The "broken-link feed
  fixer" idea is a follow-on; v1 does not ship the server-side transform
  infrastructure that would make it possible (per D6 = C, the server
  does not extract, rewrite, or otherwise transform item content; it
  fetches, parses, and stores as-delivered).
- Social-style features (sharing to public profiles, following users,
  recommendations).
- Native non-RSS sources (Mastodon, ATProto, YouTube as channels, GitHub
  releases). YouTube channels happen to expose RSS so they ride for free;
  first-class non-RSS adapters do not.

## Confirmed scope (from the initial brainstorm)

These items are baseline. The decisions below add to or refine them.

- Cloud-managed feed fetching, parsing, and storage.
- Per-feed settings:
  - Ordering (4 modes: oldest first, newest first, oldest-day-first /
    newest-within-day, newest-day-first / oldest-within-day; remember
    last-used).
  - In-feed summary by default (with link to article) or skip summary
    and show article by default.
  - Securely stored credentials for private feeds.
  - Reader view by default or native article styling by default.
  - Notification opt-in.
- Per-user favoriting and read/unread tracking.
- Filter by read / favorite / all.
- User-defined folder hierarchy.
- Proactive notifications via the existing platform notification path
  (APNs in 1.0.x; FCM later).

---

# Decisions

The decisions are grouped: architecture (1-4), scope cuts (5-8), operational
posture (9-10), per-feature design (11-17). Each is independently
answerable; some interact and those interactions are called out.

## Architecture

### Decision 1: Fetcher architecture — shared vs. per-user

**Question.** When N users subscribe to the same public feed (e.g. NYT),
does Cabalmail fetch it once for all of them or N times?

**Options.**

- **A. Per-user fetcher.** Each subscription is its own fetch job. Simple
  data model; private/authenticated feeds work naturally. Costs N×
  bandwidth, N× compute, and looks like a busy bot from a single IP block
  to publishers.
- **B. Shared fetcher for public feeds, per-user for credentialed.** Hybrid.
  Public-URL feeds dedupe at the fetch layer; the storage model splits
  "canonical feed" (shared) from "user subscription" (per-user state
  pointing at a canonical feed). Authenticated feeds bypass the shared
  cache and run per-user.
- **C. Per-user with a response cache.** All fetches go through a per-URL
  caching proxy with conditional GET. Looks like A from the data model;
  behaves close to B for bandwidth.

**Recommendation: B.** It is the architecture every mature aggregator
(Feedly, NewsBlur, Miniflux, FreshRSS) converges on. The data-model cost of
separating "feed" from "subscription" is the same cost you would pay later
if you started with A and outgrew it. C is appealing for simplicity but the
cache layer ends up doing most of B's work without B's clarity.

**Decision: B.**

**Sub-decisions if B is chosen.**

- How are feeds that look public but 401 us handled? Quarantine the
  canonical record and convert to per-user, or surface as a credential
  prompt?
  Decision: surface as a credential prompt.
- What's the canonical-URL normalizer? (Trailing slashes, scheme, `www.`
  prefix, tracking query params can each produce N copies of "the same"
  feed if not normalized.)
  Decision: Trailing slashes for URLs provided without paths. Trailing slashes where two users provide an otherwise identical URL and one includes a trailing slash and the other does not. Different query parameters count as different feeds, but order of query params should be normalized. www.<apex_domain> is the same as <apex_domain>. Other subdomains other than "www" are not equivalent to each other nor to the apex. http is **not supported**; only https. Examples:
	  - https://example.com and https://example.com/ are the same. The latter is canonical.
	  - https://example.com/ and https://www.example.com/ are the same. The latter is canonical.
	  - https://web.example.com/ and https://www.example.com/ are different.
	  - https://example.co.uk/ and https://www.example.co.uk/ are the same (apex domain with two dots is still an apex domain). The former is canonical.
	  - https://web.example.com/ and https://example.com/ are different.
	  - https://example.com/dir and https://example.com/dir/ are the same. The latter is canonical.
	  - https://example.com/?foo=bar and https://example.com/?foo=baz are different.
	  - https://example.com/?foo=bar&bin=baz and https://example.com/?bin=baz&foo=bar are the same. The latter is canonical (alphabetically normalized).
	Exception: links used as a `<guid>` should not be normalized.

### Decision 2: Folder model — Dovecot or native

**Question.** The initial brainstorm proposed implementing the folder
hierarchy in Dovecot. Should we?

**Options.**

- **A. Native model.** Feeds, items, folders, and per-user state are
  first-class tables in our own data store. Folder hierarchy is a tree we
  own.
- **B. Dovecot folders, content elsewhere.** Folder tree is an IMAP mailbox
  tree; feed items live in their own store and reference Dovecot UIDs for
  per-user flags. Users can browse feeds via any IMAP client.
- **C. Full Dovecot — feed items as RFC822 messages.** Each item becomes a
  message appended into a mailbox. IMAP becomes the API.

**Recommendation: A.** Feed items are mutable (publishers edit and re-publish
articles), and the metadata we want (source feed, fetch error, canonical URL,
extracted full text, score, original-vs-extracted HTML) does not fit IMAP
flags or message structure. The IMAP append-only model fights this domain.
B inherits all of C's problems with none of the leverage. The folder
hierarchy concept is independent of the storage engine and is cheap to build
natively. C has the further wrinkle that "favorite" and "read" are
per-user-per-item state and IMAP flags are per-mailbox; you would end up
modeling them outside IMAP anyway.

If a future version wants IMAP access to feeds (the way Gmail exposes labels
as IMAP folders), expose it as a read-only IMAP *view* layered on the native
model. Don't put the source of truth there.

**Decision: A.**

### Decision 3: Third-party API compatibility

**Question.** Should the Cabalmail RSS API be compatible with an existing
standard so existing readers (Reeder, NetNewsWire, Unread, FeedMe) work out
of the box?

**Options.**

- **A. Our own API only.** Clean, modern, matches the rest of the Cabalmail
  API surface. Locks third-party clients out.
- **B. Implement the Fever API alongside our own.** Fever is a small
  read-mostly API (~10 endpoints) spoken by a meaningful subset of readers.
- **C. Implement the Google Reader API alongside our own.** Larger surface
  but supported by more clients (NetNewsWire, Reeder 5, FeedMe). De facto
  standard.
- **D. Shape our own API to be Fever-compatible-ish without committing to
  Fever in v1.** Pick endpoint shapes and concepts so a thin compatibility
  shim is possible in a later release.

**Recommendation: D for v1, with a clear path to B in a 2.x point release.**
Locking down a compatibility API on day one slows v1 design; ignoring it
forever cuts off a meaningful audience. Designing the native API with this
option in mind keeps the door open at low cost.

**Trade-off to weigh.** Cabalmail's selling point is the integrated client
experience (BIMI, in-house Apple apps, etc.). Inviting third-party clients
dilutes that, but for RSS — where the third-party ecosystem is mature and
good — interoperability may be a stronger draw than UI consistency.

**Decision: A.** Justification:
- I'm building the RSS reader that I want to use, and I don't use Fever. Email defaults (e.g. archiving over deleting, manual mark-as-read) reflect my own preferences. I'm fine with making them configurable, but the defaults are what I want in my own email system. I intend to apply the same policy to RSS.
- I'm building a vertically integrated stack, clients and servers, and don't want to build servers that support arbitrary clients, nor clients that support arbitrary servers. I don't want to be on the hook to change my implementation if a third party client or server changes there. And I don't want the user to blame my product for poor interoperability. I won't object to or seek to prevent a third party implementing my API, but I don't intend to encourage it either. (By the way, I'm not entirely convinced that I should be exposing IMAP externally, but until my mail clients are mature, I don't have a viable alternative.)

### Decision 4: Retention policy

**Question.** How long do feed items live, and what bounds the storage?

**Options.**

- **A. Forever.** Every item ever fetched stays in the DB.
- **B. Time-based cap per feed.** Items older than N (default 90 days?) are
  deleted.
- **C. Item-count cap per feed.** Keep the most recent N items per feed
  (default 500?).
- **D. Hybrid: cap by both, favorites and saved-for-later exempt.** Items
  older than N days *or* beyond M most-recent are dropped unless flagged.
- **E. Per-user item retention quota.** Cap by total items per user
  regardless of how many feeds they have.

**Recommendation: D, with operator-tunable defaults and a per-user override.**
Without a cap, storage compounds forever and the DB becomes the bottleneck.
Favorites must be exempt or the favorite feature is a lie. A per-feed user
override lets power users keep low-volume feeds forever.

**Decision:** In-feed content is kept forever. Linked content is cached for N days where N is an operator-tuned setting.

**Sub-decision.** When an item is dropped, does the per-user "read" state go
with it (storage win) or persist as a tombstone keyed by item-GUID so a
re-fetched item does not pop up as unread again (correctness win)?
Recommend the tombstone — small per-row cost, eliminates a class of
annoying bugs.

**Decision: tombstone.**

## Scope cuts (in v1 or defer?)

### Decision 5: OPML import/export

**Question.** OPML is the standard way users move feed lists between
readers. v1 scope?

**Recommendation: yes, both in v1.** Onboarding without OPML import means
every prospective user adds feeds one at a time, which kills adoption.
Export is the corresponding exit story — without it, Cabalmail is a roach
motel for feed lists. Both are small to implement.

**Decision:** OPML is _in scope_.

**Open sub-decision.** Import behavior on collision — additive with
duplicate-feed detection by canonical URL, or replace? Recommend additive.

**Decision:** Additive.

### Decision 6: Full-text article extraction

**Question.** Many feeds publish only summaries. Should Cabalmail fetch the
linked article server-side and extract the body so the user reads the full
piece without leaving the reader?

This decision interacts with two confirmed-scope items:

- "Show in-feed summary by default with link to article, or skip in-feed
  summary and show article by default" — does "show article" mean the
  extracted full text, or does it mean opening the publisher's page in a
  web view? The two are very different scopes.
- "Reader view by default or native article styling by default" — reader
  view *requires* an extracted body. If reader view is in scope (it is),
  some form of extraction must be in scope.

**Options.**

- **A. Server-side extraction, opt-in per feed.** Default off; user toggles
  "fetch full article" per feed. Reader-view setting is moot for feeds
  where extraction is off (those feeds default to native styling).
- **B. Server-side extraction, opt-out per feed.** Default on for
  summary-only feeds; user can disable. Reader view works everywhere.
- **C. No server-side extraction; "show article" means open the publisher's
  page in a web view.** Reader view applies only to the rich-content
  feeds that already include full bodies (a lot of Atom and JSON Feed
  sources do).

**Recommendation: A in v1, evaluate moving to B in v1.1.** Server-side
extraction is the single biggest UX win of any modern reader. It is also
the same plumbing as the deferred "broken-URL fixer" idea — a server-side
transform pipeline keyed on feed identity. Shipping the pipeline behind an
opt-in toggle in v1 means the infrastructure is built; flipping the default
later is a settings change.

**Decision: C.** Attempting server-side extraction opens up too many potential rendering issues. If possible, I'd like the embedded web view to support reader mode. My current preferred feed client is Reeder, which seems to embed Apple's WebKit and supports Apple's reader view feature.

**Operator clarification needed.** Confirm which interpretation you meant
for "show article by default" in the original scope, so this decision lands
on a coherent UX rather than a contradictory mix.

**Clarification:** "show article by default" means, when a user selects a feed item from a channel, the client opens the linked article in an embedded web view. I prefer this approach not only due to the way it sidesteps rendering and fetching issues, but also because it assures that at the moment I open it, I'm getting the latest version with any corrections that might have occurred since initial publication.

**Implementation cost.** Trafilatura, Mercury Parser, or Readability.js
via Node all work. Lambda-friendly with a modest cold-start budget.
Publishers' anti-bot defenses are the main operational risk; some sites
will refuse extraction and need to fall back to "open the page."

### Decision 7: Email-to-feed (newsletter ingest)

**Question.** A growing share of users' "feeds" arrive as newsletters.
Should Cabalmail provision a magic address that ingests newsletters into
the RSS pipeline?

**Options.**

- **A. Yes, v1.** User requests a newsletter address, points Substack /
  Stratechery / etc. at it, and the newsletter appears in their feed list.
- **B. Yes, v1.1.** Defer to keep v1 scope tight.
- **C. No.** Newsletters stay in the inbox.

**Recommendation: A.** This is the differentiator. An email-platform-with-RSS
that bridges newsletters and feeds is a feature no standalone RSS reader can
match without operating its own SMTP infrastructure. Plumbing reuses
SMTP-IN, the `cabal-addresses` table, and the per-user mailbox model.
Cost is mostly UI and the rule that routes mail-to-a-newsletter-address into
feeds rather than the inbox.

**Decision: B.** The only newsletters I currently subscribe to are from Substack, which also supports feeds (RSS or Atom or both, not sure). I generally ignore the emailed version and rely on the RSS feed. (The concern for corrections is particularly sharp with email because publishers cannot retract messages already in recipients' inboxes.) And As I say, I'm building the feed reader that I want primarily. But I'm fine with keeping it on the roadmap for other users.

**Sub-decision.** One newsletter address per user with sender-based routing
into feeds, or one address per newsletter-feed? Recommend per-feed
addresses, generated on demand, revocable like normal Cabalmail addresses.
Sender-based routing is fragile (newsletter `From:` addresses change without
notice; same From: can carry multiple newsletter products).

**Decision: deferred.** If we decide to move forward after the initial release, we can revisit this issue. Today, I'm inclined to agree with the on demand approach, but let's not consider that locked in unless/until we decide to move forward with the feature.

### Decision 8: Feed-to-email digests

**Question.** Inverse of Decision 7 — should a low-volume feed be
deliverable as a daily/weekly email digest into the user's mailbox?

**Recommendation: defer to v1.1.** Useful, the plumbing exists, but it adds
UI and scheduling surface that v1 doesn't need. Worth noting now so the v1
storage model doesn't preclude it (it shouldn't — digest generation is a
pure read from the item store).

**Decision: No.** I don't see this feature adding enough UX value to justify the effort. I've already commented on the rendering challenges. This will be even harder for inbox viewing where Javascript is generally not available.

## Operational posture

### Decision 9: Outbound fetcher identity and behavior

These are checklist items the implementation plan must cover. Listed here
so they don't get lost.

- **User-Agent string.** Something like
  `Cabalmail/2.0 (+https://cabalmail.com/feedbot)` with an info page at
  that URL explaining what the bot does, how to block it, and how to
  contact the operator. Publishers expect this.
- **Egress IP stability.** Fetcher should egress from stable IPs (NAT
  instance pool or dedicated EIPs). Publishers who allowlist or
  rate-limit by IP need a target. Current NAT instances per environment
  are probably suitable — confirm.
- **Conditional GET.** Always send `If-Modified-Since` and `If-None-Match`
  based on the prior fetch's response. Non-negotiable for politeness and
  bandwidth.
- **robots.txt posture.** RSS *feed* fetches generally ignore robots.txt
  (the feed URL is the publisher's invitation). Article-extraction
  fetches (Decision 6) should honor it.
- **Retry/backoff.** Exponential backoff on 4xx/5xx, with a per-feed
  dead-letter state after N consecutive failures (surface to user; see
  Decision 10).
- **Per-feed rate limits.** Even on user request, never fetch a given feed
  more than once per N minutes (default 15?). Prevents pathological
  "refresh" loops.

**Decision:** Cabalmail wants to be a good Internet citizen and honor all conventions regarding polite, ethical, and responsible use of others' resources. I think that at least gestures at answers all of these. More specific guidance can be elucidated at implementation time.
### Decision 10: Feed health surface

**Question.** When a feed dies (404, malformed XML, certificate expiry,
redirect loop), how does the user find out?

**Options.**

- **A. Silent.** Stale feed stops updating. User notices when they realize
  there has been no new content.
- **B. Per-feed health status in the UI.** Last-fetch time, last error,
  HTTP status, redirect chain. User can drill in.
- **C. B plus proactive notification.** Push notification after N days of
  failure on a subscribed feed, or immediately on hard-fail (410 Gone).

**Recommendation: B in v1, C as opt-in in v1.1.** Visibility is table stakes;
proactive notification needs care not to become noise (a feed flapping
between 200 and 503 shouldn't notify on every flip).

**Decision: B.** I'm skeptical of even wanting C. I think an in-app message ought to be enough. I might reconsider after using the product for a while.

## Per-feature design

### Decision 11: Credentialed feed schemes

**Question.** Which authentication schemes for private feeds do we support
in v1?

**Options.**

- **A. HTTP Basic only.** Simplest. Covers a meaningful share of private
  feeds.
- **B. Basic + cookie-based.** Adds support for some paywalled feeds where
  the publisher mints a session cookie tied to a long-lived URL.
- **C. Basic + cookie + API-key-in-URL.** Many "private" feeds embed a
  token directly in the feed URL (e.g.
  `https://example.com/feed?key=abc123`). This requires no auth-storage
  code per se, but should be flagged as a security/privacy item (the key
  is in our DB; revoking access means rotating the feed URL on the
  publisher's side).
- **D. All of the above + OAuth.** OAuth is the only path to some
  paywalled providers (Bloomberg, FT) and is a quarter-long project in
  its own right (per-provider integration, refresh token storage, KMS,
  etc.).

**Recommendation: C in v1.** Basic covers the easy case; URL-embedded keys
cover the next-easiest; cookies are a modest extension. OAuth deferred to a
follow-on with its own design pass.

**Decision: C.** Additional cookie-handling requirements:
- I'd like cookies to be scoped to each feed. E.g., if I have three Substack feeds, each feed has to set it's own cookies. This allows users to subscribe using distinct email addresses for each feed and prevents tracking across feeds.
- The local storage objects for the embedded web view should likewise have per-feed scope. E.g. if I drill past the feed summary to a subscriber-only article on the publisher's site, I'd like to be able to authenticate on the site within the web view experience and have any stored tokens perserved across sessions. Scenario: I subscribe to two Substack newsletters with two different email addresses. I want to read subscriber-only article 1 from Substack feed A. I drill past the feed summary to see the article in web view. Because it's subscriber-only, I have to enter my Substack feed A email address and then enter a code sent to my inbox. I later want to read subscriber-only article 2 from Substack feed B. I drill past the feed summary to see the article in web view. Although I have previously authenticated for feed A, feed B has it's own local storage which is not intermingled with feed A's local storage. I therefore have to go through the same email validation using my Substack feed B email address. Thereafter, I can read subscriber-only articles in both feeds as long as each feeds locally stored tokens have not expired. I like having different emails for each feed, and having my feed reader mix up the authentication between them is inconvenient.

**Storage.** Credentials in SSM SecureString, KMS-encrypted, keyed by
`(user, feed_id)`. Consider whether shared canonical feeds (Decision 1B)
inherit credentials from the first subscriber or whether each subscriber
stores their own — recommend the latter (no cross-user credential leakage
risk) which implies credentialed feeds bypass the shared-fetcher path.

**Decisions:** No shortcuts with user credentials. Only public feeds get shared fetching.

### Decision 12: Notification defaults and granularity

**Question.** Notifications are per-feed opt-in in the confirmed scope.
Should the opt-in be available at per-folder level too? What's the default
for a freshly subscribed feed?

**Options.**

- **A. Per-feed only, default off.** User opts in feed by feed.
- **B. Per-feed and per-folder, default off, folder override wins for feeds
  that don't set their own.** Adding a feed to a "Critical" folder picks
  up that folder's "notify on" setting.
- **C. Default on for low-volume feeds, off otherwise.** Heuristic based on
  observed post rate; threshold (e.g., <=3 items/day) operator-tunable.

**Recommendation: B with default off.** Two levels of granularity match how
users naturally think about it ("everything in this folder is important").
Default off is safer than the alternatives and the push-budget math is
friendlier. C is clever but surprising — users will be confused why some
feeds notify and others don't.

**Decision:** A for v1.0, B on the roadmap.

### Decision 13: Image and asset handling

**Question.** Articles embed images hosted on publishers' CDNs. What does
Cabalmail do with them?

**Options.**

- **A. Pass through.** Render the original URL in the client. Publisher
  sees the client's IP and any tracking pixels fire on read.
- **B. Server-side proxy.** All `<img>` URLs rewritten through a Cabalmail
  proxy. Publisher only sees Cabalmail's IPs. Reduces tracking; improves
  privacy.
- **C. Proxy + cache.** B plus cache fetched images so 404s on the
  publisher side don't break archived articles.

**Recommendation: C, with a modest cache TTL (7 days?).** The privacy win
is significant — feed readers are routinely targeted with tracking pixels —
and the operational cost is bounded. The cache also makes the retention
story (Decision 4) more honest: an article kept for 90 days won't be a
broken-image graveyard.

**Cost.** Bandwidth and S3 storage. Worth a back-of-envelope estimate
before committing — if a typical article has 5 images at 200 KB each, a
user with 50 articles a day at 90-day retention pulls 4.5 GB of image
cache. Tractable, but not free.

**Decision: C** with 7 day TTL.

### Decision 14: Filter and search

Confirmed scope includes filter by read/favorite/all. Open questions:

- **Full-text search across all subscribed feeds.** Server-side, since
  Cabalmail has the corpus. **Recommend in v1.** Cost depends on storage
  engine (Decision 4 sub-question) — DynamoDB needs an external index
  (OpenSearch); Postgres can use built-in tsvector at this scale.
- **Per-feed keyword mute** (the read-side sibling of the broken-URL
  fixer). Hide items matching a user-defined pattern. **Recommend defer
  to v1.1** — the transform pipeline (Decision 6) will already support
  it; only the rule editor needs UI work.
- **Tagging in addition to folders.** Folders are exclusive, tags are not.
  Useful but adds modeling complexity. **Recommend defer.**

**Decisions:**
- Can we use Aurora Postgres with tsvector?
- No per-feed keyword muting.
- I don't use tags with my feed reader today, and I don't miss them, so keep it on the roadmap for other users' benefit, but not for 1.0.

**Revised decision (after design exploration):** Server-side full-text
search deferred indefinitely (the Aurora-vs-DynamoDB cost comparison
under Open Q2 made Postgres tsvector too expensive at hobby scale, and
OpenSearch is worse). The operator confirmed cross-feed FTS is not a
real-world need. **Per-feed FTS moves to Apple clients only,** backed
by a local SQLite/FTS5 item cache that doubles as the offline-reading
store (see new Decision 18). React has no search in v1; this is a
documented limitation. Cross-feed search remains out. The "per-feed
keyword mute" and "tagging" decisions above are unchanged.

### Decision 15: Read-state and reading-assistance features

| Feature                  | Description                                     | v1 recommendation                | Decision                                                                                                                 |
| ------------------------ | ----------------------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Mark-all-as-read         | Per feed, per folder, global                    | **In** — table stakes            | **In**                                                                                                                   |
| Save-for-later           | Reading-intent flag distinct from favorite      | Defer                            | **Defer**                                                                                                                |
| Snooze                   | Hide article until time T                       | Defer                            | **Out**                                                                                                                  |
| Keep-unread pin          | Prevent auto-mark-read on a specific item       | Defer                            | Marking as read should be **manual** by default. Auto-mark-as-read should be a per-user optional setting (not per-feed). |
| Auto-mark-read on scroll | Vs. explicit only                               | **In**, user-toggle, default off | **Defer**                                                                                                                |
| Cross-feed dedup         | Same article syndicated in N feeds appears once | Defer to v1.1                    | **Out**                                                                                                                  |
| Reading-time estimate    | Per article, from extracted text                | **In** — trivial                 | **In** — make it optional and off unless user opts in (want to avoid distracting UI elements)                            |

### Decision 16: JSON Feed support

Trivial to add alongside RSS/Atom; the parser library choice usually covers
all three. **Recommendation: in v1.**

**Decision: In**

### Decision 17: Cadence

What is the default fetch cadence for a feed? Are per-user overrides
allowed?

**Recommendation:** default cadence of every 60 minutes; an
operator-configurable "high-velocity" tier (every 15 minutes) for major
news sources; per-user override bounded to operator-set min/max. Cadence
is per-feed not per-user (a shared canonical feed under Decision 1B has a
single fetch cadence — the maximum of any subscriber's requested cadence,
clamped to the operator's bounds).

**Decision:** I'd like the server to assess feed velocity over time and dynamically adjust cadence within operator-set bounds. I don't want to expose cadence settings to end users.

### Decision 18: Offline reading on Apple clients

*Added after design exploration; not present in the original decision set.*

**Question.** The local item cache that backs Apple-side per-feed FTS
(see **Revised decision** under Decision 14) naturally also enables
offline reading. Should offline reading be a first-class requirement?

**Decision: yes.** The operator uses offline reading regularly on the
current reader (Reeder) and expects parity. Offline reading covers
in-feed content (summary plus any `content_html` the feed delivered).
Articles opened in the embedded web view still require network — per
Decision 6 we do not extract or cache article bodies server-side, and
the WKWebView's article rendering is a live publisher fetch. Images
inside in-feed content rely on whatever the embedded `URLCache` happens
to have picked up from prior online viewing; explicit aggressive
pre-cache of image bytes is deferred.

Offline mutations (mark-as-read, favorite/unfavorite) are queued in a
small local pending-mutations table and dispatched to the server on
reconnect with last-write-wins semantics. Cache retention defaults and
the cross-device inconsistency story are implementation details captured
in the companion plan.

---

## Cross-cutting items to design into v1 even if features defer

These exist to keep doors open. They are not optional; they constrain the
v1 data model and are cheap if done up front, expensive if retrofitted.

- **Per-user-per-item state separate from item content.** Required by
  Decision 1 (shared feeds) so per-user mutations don't write into
  shared item rows. The `(user, item_id) -> {read, favorite, ...}`
  table is the keystone of the storage model.
- **Canonical URL normalizer** (Decision 1 sub-decision). Must exist
  before two users subscribe to "the same" feed via different URL forms.

*(Two items previously listed here are moot under the operator's
decisions: a tombstone table — D4 chose "items kept forever," so items
are never dropped — and a per-feed server-side transform pipeline — D6
chose option C, no server-side extraction or rewriting. The
implementation plan does not include either.)*

## Open questions for the operator

1. **Roadmap version.** Does this fit at 2.0, or does it span 2.0 / 2.1 /
   2.2 once the decisions land? My instinct is that v1-as-described-here
   is 2.0; the basic reader UI plus all of the in-scope items above is
   plenty for a single release.
   **Decision**: 2.0.
2. **Storage engine for feed items.** Extend DynamoDB usage (no joins,
   limited search), introduce Postgres (joins, full-text via tsvector,
   familiar to the operator?), or something else? Largely determined
   by Decision 4 (retention complexity) and Decision 14 (search).
   **Decision:** Postgres Aurora tsvector.
   **Revised decision (after design exploration):** DynamoDB as the sole
   data store; Aurora Postgres deferred indefinitely. The original choice
   was undone after Aurora's ~$45/env/month idle floor (scale-to-zero
   doesn't help in practice because the fetcher tick would keep the
   cluster warm) proved hard to justify at hobby scale. Search moves to
   the client per the **Revised decision** under Decision 14.
3. **Hosting.** Does the fetcher run as its own ECS service (long-running
   pollers, conditional-GET state per feed, per-feed cadence scheduler)
   or as a scheduled Lambda (simpler, but state lives elsewhere and cold
   starts complicate conditional GET)? My lean is a dedicated ECS service
   in the existing cluster.
   **Decision:** Let's start with scheduled Lambda and see how well it scales.
4. **Authorization.** Feed subscriptions are per-user Cognito identity,
   like every other Cabalmail per-user concept. Confirm.
   **Confirmed.**
5. **Multi-tenancy boundary.** With shared canonical feeds (Decision 1B),
   any per-user customization that touches *content* (e.g. server-side
   transforms with credentials) needs to be careful not to leak between
   subscribers. The recommended pattern — shared feeds are public-only,
   credentialed feeds are per-user — sidesteps this, but it should be
   stated explicitly as an invariant.
   **Decision:** Any user customizations are **stored** in the cloud but **applied** on the client. This allows public feeds to be shared and also customized.
6. **Client cut.** v1 ships in which clients — React admin, iOS, macOS,
   Android, all at once, or staged? The Apple clients can't be staged
   independently because they share `CabalmailKit`; the React app is
   independent of both. Android will likely lag (still in 1.1.x
   roadmap).
   **Decision:** Phased rollout is fine. 2.0.x has plenty of unused values for x.

## Next step

The companion [`rss-implementation-plan.md`](./rss-implementation-plan.md)
sequences the changes into shippable phases, names the modules and
services, identifies the data model and API shape, and lays out the
migration path from "no RSS in 1.x" to "RSS GA in 2.x". It reflects the
**Revised decision** annotations above (DynamoDB primary store; per-feed
FTS on Apple clients only; offline reading on Apple as a first-class
requirement).

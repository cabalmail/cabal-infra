# BIMI end-to-end

## Context

BIMI ("Brand Indicators for Message Identification") lets receiving mail
clients display a sender's brand logo alongside each message in the
mailbox list. A sender publishes a TXT record at
`default._bimi.<domain>` pointing at an SVG Tiny PS logo; the receiving
client looks the record up at render time, fetches the SVG, and shows it
in the message row. It is increasingly the default visual treatment in
Gmail, Apple Mail, Yahoo, Fastmail, and others.

Three things are wrong with our BIMI story today:

1. **React admin app lost BIMI display in the redesign.** The API
   client method
   [`getBimiUrl`](../../react/admin/src/ApiClient.js) is still
   exposed at lines 101-116, but nothing in
   `react/admin/src/Email/Messages/` calls it. The current
   [`Envelope.jsx`](../../react/admin/src/Email/Messages/Envelope.jsx)
   row renders an unread dot and the sender name but no logo.
2. **Apple clients never had BIMI display.** The Swift API client
   already exposes
   [`fetchBimiURL(senderDomain:)`](../../apple/CabalmailKit/Sources/CabalmailKit/API/URLSessionApiClient.swift)
   (lines 104-114), but
   [`MessageRow`](../../apple/Cabalmail/Views/MessageListView.swift)
   in `MessageListView.swift` does not call it. The row's leading
   element is an unread dot.
3. **`fetch_bimi` is not spec-correct.** The Lambda at
   [`lambda/api/fetch_bimi/function.py`](../../lambda/api/fetch_bimi/function.py)
   has been observed failing to locate BIMI logos that other email
   clients successfully render. The defects are concrete (see "Current
   state" below) and account for the unreliability.
4. **Cabalmail's own mail domains do not publish BIMI.** There are no
   `default._bimi.*` TXT records in
   [`terraform/infra/modules/app/`](../../terraform/infra/modules/app/)
   or
   [`terraform/infra/modules/front_door/`](../../terraform/infra/modules/front_door/),
   so mail we originate appears in other clients without our mark even
   when those clients support BIMI.

This plan fixes all four in five independently-shippable phases.

## Goals

- Render a per-sender BIMI logo (or a deterministic letter-glyph
  fallback) to the left of every row in the message list, on the
  React admin app and on the iOS, iPadOS, macOS, and visionOS Apple
  clients.
- Replace today's unread-dot treatment with a 2 px border ring around
  that logo on unread messages. The dot goes away.
- Make `fetch_bimi` a spec-correct, defensive proxy: extract the
  organizational domain via the Public Suffix List, parse TXT tags
  tolerantly, fetch and validate the SVG server-side against SVG Tiny
  PS, cache it in S3, and return a URL on infrastructure we control.
- Publish valid BIMI TXT records on every mail-bearing subdomain of
  every domain in `TF_VAR_MAIL_DOMAINS`, pointing at an SVG Tiny PS
  rendering of the Cabalmail mark derived from
  [`apple/handoff/cabalmail-mark.svg`](../../apple/handoff/cabalmail-mark.svg),
  hosted on the existing worldwide `front_door` CloudFront.

## Non-goals

- **VMC.** A Verified Mark Certificate (DigiCert, Entrust, ~$1500/yr)
  is required by Gmail for BIMI rendering but not by Apple Mail,
  Fastmail, Yahoo, or most other clients. Out of scope for 1.1.x;
  see "Future work" below.
- **Non-SVG logo formats.** BIMI is SVG Tiny PS only; PNG/JPG fallbacks
  are not part of the spec and are not supported here.
- **Historical recovery of the pre-redesign React layout.** This plan
  adds the BIMI slot to the current `Envelope.jsx` structure. It does
  not attempt to recreate any pre-redesign row layout.
- **Per-recipient or per-mailbox BIMI variants.** One mark per
  Cabalmail mail domain, applied via wildcard.

## Current state

### `fetch_bimi` defects

[`lambda/api/fetch_bimi/function.py`](../../lambda/api/fetch_bimi/function.py),
the entire file:

```python
sender_domain_parts = sender_domain.split(".")
length = len(sender_domain_parts)
for part in range(length):
    domain = ".".join(sender_domain_parts[part:])
    try:
        answer = dns.resolver.query(f'default._bimi.{domain}', 'TXT')
        return {
            "statusCode": 200,
            "body": json.dumps({
                "url": str(answer[0]).split(";")[1].split("=")[1]
            })
        }
    except dns.resolver.NXDOMAIN: pass
    except dns.resolver.NoAnswer: pass

return {
    "statusCode": 200,
    "body": json.dumps({
        "url": f'https://www.{".".join(sender_domain_parts[length-2:])}/favicon.ico'
    })
}
```

Defects, in order of impact:

- **Wrong scope discovery.** Walks every superdomain suffix
  (`a.b.c.com` -> `b.c.com` -> `c.com` -> `com`), querying invalid
  scopes including TLDs. BIMI requires computing the organizational
  domain via the Public Suffix List and querying once at that scope
  (and at most one fallback to the org domain when the message-from
  subdomain has no record).
- **Brittle TXT parsing.** `str(answer[0]).split(";")[1].split("=")[1]`
  assumes a fixed tag order with `l=` second. A record of
  `v=BIMI1; a=https://example.com/vmc; l=https://example.com/logo.svg`
  extracts the VMC URL instead of the logo. There is no validation
  that `v=BIMI1` is present.
- **Narrow exception handling.** Only `NXDOMAIN` and `NoAnswer` are
  caught. A transient `dns.resolver.Timeout` or upstream `SERVFAIL`
  raises out of the handler, producing a 5xx to the client instead of
  the spec-correct "no BIMI here, render a fallback" signal.
- **No SVG fetch or validation.** Returns the third-party URL verbatim
  to the client, which then loads attacker-controlled SVG directly.
  BIMI requires SVG Tiny PS; the spec is restrictive about what
  elements may appear, and a non-compliant SVG should not be
  rendered.
- **Favicon fallback is a guess.** `https://www.<lasttwo>/favicon.ico`
  may or may not exist; the path concatenates the last two labels of
  the sender domain regardless of whether that is the org domain.
- **No persistent caching.** API Gateway has a 3600 s response cache,
  but per-domain DNS lookups and per-request SVG validation happen on
  every miss.

### React client status

[`react/admin/src/ApiClient.js:101-116`](../../react/admin/src/ApiClient.js)
still defines `getBimiUrl(sender)`. No component in
`react/admin/src/Email/Messages/` calls it.

The row component
[`Envelope.jsx`](../../react/admin/src/Email/Messages/Envelope.jsx)
has a clear insertion slot: the `envelope-leading` span at
lines 106-120 currently holds the unread dot and the selection
checkbox. The BIMI logo (or fallback glyph) belongs in that span,
sized at roughly 24 x 24 px, with the unread treatment switching from
a sibling dot to a border ring around the logo.

### Apple clients status

[`URLSessionApiClient.fetchBimiURL`](../../apple/CabalmailKit/Sources/CabalmailKit/API/URLSessionApiClient.swift)
already exists at lines 104-114 and returns `URL?` from the
`/fetch_bimi` Lambda. No call site invokes it.

The iOS row is `MessageRow` inside
[`apple/Cabalmail/Views/MessageListView.swift`](../../apple/Cabalmail/Views/MessageListView.swift),
roughly lines 293-360. The macOS row is the equivalent view in
`apple/CabalmailMac/`. Both currently lead with an 8 pt unread
circle.

The sender domain is available as `envelope.from.first?.host` on
[`Envelope`](../../apple/CabalmailKit/Sources/CabalmailKit/Models/Envelope.swift);
the display name (when present) is
`envelope.from.first?.name`, and the local-part is
`envelope.from.first?.mailbox`.

No image-cache library is in the project; the Apple-side cache is a
small `actor` over `[String: URL?]` keyed by sender domain.

### Publishing infrastructure

- DKIM/SPF/DMARC are published by
  [`terraform/infra/modules/app/global_dns.tf`](../../terraform/infra/modules/app/global_dns.tf)
  and
  [`terraform/infra/modules/app/dmarc_user.tf`](../../terraform/infra/modules/app/dmarc_user.tf).
  DMARC is `p=reject` on the control domain, which qualifies the
  domain for BIMI.
- The admin CloudFront
  ([`terraform/infra/modules/app/cloudfront.tf:67`](../../terraform/infra/modules/app/cloudfront.tf))
  is `whitelist`-restricted to `US`. BIMI lookups come from receiving
  MTAs and clients worldwide; the admin distribution is unsuitable
  for hosting any BIMI asset.
- The `front_door` site at `www.<control_domain>` is already
  worldwide:
  [`terraform/infra/modules/front_door/main.tf:108`](../../terraform/infra/modules/front_door/main.tf)
  sets `restriction_type = "none"`. Content ships through
  `.github/workflows/app.yml` -> `.github/scripts/render-front-door.py`
  -> `s3 sync s3://www.<control_domain>` plus a CloudFront
  invalidation. This is the right surface for both the Cabalmail
  BIMI SVG and the static letter-glyph fallback assets.
- The handoff mark
  [`apple/handoff/cabalmail-mark.svg`](../../apple/handoff/cabalmail-mark.svg)
  is 600 bytes, no styles, no scripts, no gradients, no external
  refs - very close to SVG Tiny PS already. It needs `version="1.2"`,
  `baseProfile="tiny-ps"`, a `<title>` element, and an opaque
  background rectangle covering the viewBox.

## Glyph-letter derivation

Every client uses the same derivation to pick a fallback letter when
the sender has no BIMI record. Defined once here, mirrored in code on
each platform.

1. Parse the `From` header for a display name. If non-empty, scan it
   left-to-right for the first character matching `[A-Za-z]`. Use
   that character.
2. Otherwise, take the local-part of the address (the part before
   `@`) and scan left-to-right for the first character matching
   `[A-Za-z]`. Use that character.
3. Uppercase the chosen character. If no alphabetic character was
   found anywhere, use a literal `?`.

Reference cases (used as test fixtures on every client):

| `From` value                              | Letter |
| ----------------------------------------- | ------ |
| `4sfg@example.com`                        | `S`    |
| `<4sfg@example.com>`                      | `S`    |
| `Mary Miller <4sfg@example.com>`          | `M`    |
| `mary miller <4sfg@example.com>`          | `M`    |
| `1234@example.com`                        | `?`    |

The letter selects a static SVG at
`https://www.<control_domain>/assets/bimi-glyphs/<letter>.svg`
(lowercase filename), pre-rendered as part of Phase 2.

## Phases

Each phase ships independently. UI phases (3, 4) route through stage
per CLAUDE.md; the others qualify as direct-to-prod-eligible (no data
plane impact, no user-facing surface change in isolation, no IAM
implications, purely additive).

### Phase 1: spec-correct `fetch_bimi`

Goal: turn the Lambda into a defensive proxy that returns either a
validated SVG URL on infrastructure we control, or `null`.

- Add `publicsuffixlist` (or `tldextract`) to
  [`lambda/api/fetch_bimi/requirements.txt`](../../lambda/api/fetch_bimi/requirements.txt).
  Extract the organizational domain from the sender domain before
  any DNS query.
- Query `default._bimi.<org_domain>` exactly once. If `NXDOMAIN` /
  `NoAnswer`, return `{ "url": null }`. Do not walk superdomains.
- Parse the TXT record by splitting on `;`, trimming, and
  tokenizing each `key=value` pair. Require `v=BIMI1`. Extract `l=`
  by name. Ignore unknown tags. Reject records missing `l=`.
- Fetch the SVG with `requests` (or `urllib`) using a 5 s timeout
  and a 32 KB response size cap. Reject larger payloads.
- Validate the SVG: parses as well-formed XML, root element is
  `<svg>` with `baseProfile="tiny-ps"`, no `<script>` anywhere, no
  `xlink:href` referring to anything off-document, no `<foreignObject>`,
  no `<image>` with external `href`. Reject otherwise.
- Cache validated SVGs to a new S3 bucket `bimi-cache.<control_domain>`
  (or a prefix on the existing admin bucket, if simpler) keyed by
  org domain, with a 24 h TTL set via S3 object metadata and a
  Lambda-side timestamp check on each request. Return the public
  HTTPS URL of the cached object.
- Broaden exception handling: catch every
  `dns.exception.DNSException`, every `requests.RequestException`,
  every XML/parse error. Log structured, return `{ "url": null }`,
  never raise.
- Drop the favicon fallback entirely. The client decides what to
  render when the URL is `null`.

Unit tests in `lambda/api/fetch_bimi/` cover:

- Valid record with `v=BIMI1; l=<url>`.
- Reordered tags (`a=` before `l=`).
- Missing `v=BIMI1`.
- `NXDOMAIN`, `NoAnswer`, `Timeout`, `SERVFAIL`.
- Oversized SVG (33 KB).
- SVG containing `<script>`.
- Malformed XML.
- Subdomain with no record, org domain with a record (should it
  fall back to org? Spec says yes for *some* subdomains; document
  decision in the test).

### Phase 2: letter-glyph fallback assets

Goal: ship 27 static SVGs (`a` ... `z`, `?`) on the front_door site
so every client has a deterministic, branded fallback when a sender
has no BIMI record.

- Add `front-door/assets/bimi-glyphs/<letter>.svg` for each letter.
  Each SVG is a square, opaque, Cabalmail-palette plate with the
  capital letter centered. SVG Tiny PS-clean (the same constraints
  as the brand mark) so the file format is reusable by anything
  reading it.
- Two visual treatments authored: a primary monogram-on-cream
  (matches the handoff palette) and a tinted variant. Pick one as
  the default for the clients; the other is a stylesheet/asset
  swap.
- The existing front_door deploy pipeline ships these without
  workflow changes; they show up at
  `https://www.<control_domain>/assets/bimi-glyphs/<letter>.svg`
  after the next push that touches `front-door/**`.

### Phase 3: React client display

Goal: BIMI logo (or fallback glyph) in the `Envelope.jsx` leading
slot, with unread indicated by a 2 px border ring.

- Add a `getInitialGlyph(from)` utility at
  `react/admin/src/utils/initialGlyph.js` implementing the
  derivation above. Unit tests cover the five reference cases.
- Add a `useBimiUrl(senderDomain)` hook (or extend the existing
  envelope-list state) that calls `ApiClient.getBimiUrl` once per
  domain per session and memoizes results in component-tree state.
  Coalesce concurrent calls for the same domain.
- In
  [`Envelope.jsx`](../../react/admin/src/Email/Messages/Envelope.jsx),
  render inside the `envelope-leading` span:
  - If `bimi.url` is a non-null string, an `<img>` at 24 x 24 px
    with `src={bimi.url}`.
  - Otherwise, an `<img>` at 24 x 24 px with
    `src={"/assets/bimi-glyphs/" + getInitialGlyph(from) + ".svg"}`
    served from the same `www.<control_domain>` host (cross-origin
    is fine; the SVGs are public).
- Replace the unread dot. Add a `unread` CSS class on the logo
  container that draws a 2 px border ring picking up the existing
  unread-accent color variable.
- Update `Envelope.test.jsx`, `Envelopes.test.jsx`, and the viewport
  tests in `Messages.viewport.test.jsx` to cover the new slot and
  the border-ring unread state.

### Phase 4: Apple client display

Goal: parity with the React change on iOS, iPadOS, macOS, visionOS.

- Add a `BimiCache` actor in
  `apple/CabalmailKit/Sources/CabalmailKit/BIMI/` keyed by sender
  domain. Memory cache only; the server-side cache from Phase 1 is
  authoritative. Coalesce concurrent fetches for the same domain.
- Add a `BimiFallback` helper in the same directory with
  `static func glyphLetter(from: EmailAddress) -> Character`
  implementing the derivation. Tests in
  `apple/CabalmailKit/Tests/CabalmailKitTests/BimiFallbackTests.swift`
  cover the same five reference cases.
- Add a `wwwBaseURL: URL` (or similar) field to
  [`Configuration`](../../apple/CabalmailKit/Sources/CabalmailKit/Config/Configuration.swift)
  so the static-asset host is configurable per environment.
- In `MessageRow` in
  [`apple/Cabalmail/Views/MessageListView.swift`](../../apple/Cabalmail/Views/MessageListView.swift)
  and the macOS row equivalent, insert an image view (e.g.
  `AsyncImage` with a fallback `Image`) at 24 x 24 pt sourced
  from `BimiCache.url(for:)`. Apply a `.overlay` with a 2 pt
  rounded border on unread rows; remove the unread dot.
- When `BimiCache` returns `nil`, request
  `\(configuration.wwwBaseURL)/assets/bimi-glyphs/\(letter).svg`
  with the same image view.
- Tests: extend
  [`ApiBackedImapClientTests.swift`](../../apple/CabalmailKit/Tests/CabalmailKitTests/ApiBackedImapClientTests.swift)
  with a `fetchBimiURL` stub; add `BimiCacheTests` for coalescing
  and basic cache hits/misses.

### Phase 5: publish BIMI for Cabalmail domains

Goal: every domain in `TF_VAR_MAIL_DOMAINS` publishes a working
`default._bimi` record pointing at the Cabalmail mark.

- Adjust the handoff mark into SVG Tiny PS form:
  - Add `version="1.2"` and `baseProfile="tiny-ps"` on the root.
  - Add `<title>Cabalmail</title>` as the first child of the root.
  - Add an opaque background `<rect>` covering the viewBox in
    `--cm-cream` (`#F4EBD6`).
  - Strip the `&#xA;` whitespace artifacts from the path data.
  - Save at `front-door/assets/bimi/cabalmail.svg`. Ships through
    the existing front_door pipeline.
- Add Terraform records. Pattern follows
  [`terraform/infra/modules/app/dmarc_user.tf`](../../terraform/infra/modules/app/dmarc_user.tf).
  Create them either in a new `bimi.tf` inside the `app` module or
  in a small dedicated `bimi` module - whichever keeps the
  `for_each = var.domains` iteration cleanest. Each record:

  ```hcl
  resource "aws_route53_record" "bimi" {
    for_each = { for d in var.domains : d.domain => d }
    zone_id  = each.value.zone_id
    name     = "default._bimi.*.${each.value.domain}"
    type     = "TXT"
    ttl      = 3600
    records  = ["v=BIMI1; l=https://www.${var.control_domain}/assets/bimi/cabalmail.svg"]
  }
  ```

- Wildcard TXT support varies by resolver. If field-testing with
  `dig TXT default._bimi.<some-subdomain>.<domain>` from multiple
  vantage points shows the wildcard not being honored, switch to
  an explicit list driven by a new variable
  `var.bimi_subdomains = ["mail-admin", ...]` and iterate. The
  doc captures both forms; the wildcard is the preferred starting
  point.
- After apply, validate with
  [bimigroup.org/bimi-inspector](https://bimigroup.org/bimi-inspector)
  for a known sender subdomain. Once verified, document the
  inspector URL and `dig` commands in
  [`docs/operations.md`](../operations.md).

## Verification

Each phase verifies end-to-end before merging.

- **Phase 1.** `cd lambda/api/fetch_bimi && python -m pytest` against
  the new tests. Smoke-test in stage by hitting
  `/fetch_bimi?sender_domain=cnn.com`, `/fetch_bimi?sender_domain=google.com`,
  and a domain known to have no BIMI; observe `url` is a non-null
  S3-backed URL in the first two cases and `null` in the third.
- **Phase 2.** Push the front_door change; visit
  `https://www.<control_domain>/assets/bimi-glyphs/m.svg` and
  confirm the rendered glyph.
- **Phase 3.** `cd react/admin && npm run test`. Manually load the
  admin app, confirm logos render for messages from known
  BIMI-publishing senders, fallback glyphs render for the rest, and
  the unread border ring shows on unread rows.
- **Phase 4.** `cd apple/CabalmailKit && swift test`. Build and run
  the iOS app on a real device; confirm same as Phase 3. Repeat on
  macOS.
- **Phase 5.** From outside the Cabalmail VPC,
  `dig TXT default._bimi.<some-mail-subdomain>.<cabalmail-domain>`
  returns the expected record. Send a test email from a Cabalmail
  address to a Gmail account and a Fastmail account; confirm the
  Cabalmail mark renders (Gmail will require a VMC, so the mark
  appears in Fastmail but not Gmail - that is expected and matches
  the "VMC deferred" non-goal).

## Future work

- **VMC.** Once the rest of the pipeline is solid, a Verified Mark
  Certificate from DigiCert or Entrust (~$1500/yr) unlocks BIMI
  display in Gmail. The change at our end is one tag added to each
  TXT record: `a=https://www.<control_domain>/assets/bimi/cabalmail.pem`,
  with the certificate file hosted alongside the SVG. The
  certificate itself is the cost; the wiring is trivial.

## Rollout notes

- Phase 1 (Lambda), Phase 2 (static glyphs), and Phase 5 (Terraform
  TXT records plus front_door SVG) are direct-to-prod-eligible per
  the "Direct-to-prod scaffolding" rules in
  [`CLAUDE.md`](../../CLAUDE.md):
  no data plane impact, no user-facing surface change in isolation,
  no IAM/security implications, purely additive.
- Phase 3 (React) and Phase 4 (Apple) are user-facing UI changes
  and route via stage as usual.

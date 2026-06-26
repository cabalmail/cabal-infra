# BIMI end-to-end

## Context

BIMI ("Brand Indicators for Message Identification") lets receiving mail
clients display a sender's brand logo alongside each message in the
mailbox list. A sender publishes a TXT record at
`default._bimi.<domain>` pointing at an SVG Tiny PS logo; the receiving
client looks the record up at render time, fetches the SVG, and shows it
in the message row. It is increasingly the default visual treatment in
Gmail, Apple Mail, Yahoo, Fastmail, and others.

This plan was originally written to fix four problems at once. Two are
done and the other two are partly done; see **Already shipped** for what
landed piecemeal during 0.9.x/0.10.x. What remains:

1. **`fetch_bimi` is not spec-correct.** The Lambda at
   [`lambda/api/fetch_bimi/function.py`](../../lambda/api/fetch_bimi/function.py)
   has had its DNS timeouts and exception handling hardened, but it still
   walks superdomains instead of computing the organizational domain,
   parses the TXT record positionally, returns the third-party logo URL
   verbatim (no fetch, no validation, no caching on infrastructure we
   control), and still falls back to a guessed `favicon.ico`. See
   "Remaining `fetch_bimi` defects" below.
2. **React admin app has no BIMI display.** The API client method
   [`getBimiUrl`](../../react/admin/src/ApiClient.js) is exposed (around
   line 120) but nothing in `react/admin/src/Email/Messages/` calls it.
   The [`Envelope.jsx`](../../react/admin/src/Email/Messages/Envelope.jsx)
   row still leads with an unread dot and a selection checkbox, no logo.
   The Apple clients already ship the equivalent display (see below);
   React needs to reach parity.
3. **Cabalmail's own mail domains do not publish BIMI.** There are no
   `default._bimi.*` TXT records in
   [`terraform/infra/modules/app/`](../../terraform/infra/modules/app/),
   so mail we originate appears in other clients without our mark even
   when those clients support BIMI.

## Already shipped

- **Apple client display (was Phase 4).** The iOS/iPadOS/macOS/visionOS
  clients render a sender avatar in both the message-list row
  ([`MessageListView+Rows.swift`](../../apple/Cabalmail/Views/MessageListView+Rows.swift))
  and the detail header
  ([`MessageDetailView.swift`](../../apple/Cabalmail/Views/MessageDetailView.swift))
  via [`AvatarView`](../../apple/Cabalmail/Views/AvatarView.swift), with
  a three-tier source precedence: the sender's Apple Contacts photo, then
  the domain's BIMI logo (resolved through
  [`BimiUrlCache`](../../apple/CabalmailKit/Sources/CabalmailKit/API/BimiUrlCache.swift),
  a session-scoped, coalescing, domain-keyed actor over
  `fetchBimiURL`), then a deterministic colored initials circle.

  This diverged from the original plan in two ways that are now the
  intended design, not debt:
  - The no-BIMI fallback is a **natively drawn initials circle**, not a
    pre-rendered letter-glyph SVG. The plan's Phase 2 (ship 27
    `bimi-glyphs/<letter>.svg` assets) is therefore **dropped** — no
    client needs them.
  - The unread indicator stays a **separate dot**; the avatar occupies
    its own slot. The plan's "replace the dot with a border ring around
    the logo" idea was **not** adopted and is not pending work.
- **`fetch_bimi` DNS hardening (part of the old Phase 1).** Input is
  validated with `validate_dns_apex` (400 on bad input), the resolver is
  time-bounded, the whole suffix walk is capped by a wall-clock budget,
  and every `dns.exception.DNSException` is caught so a slow or hostile
  authoritative NS can no longer turn into a 5xx. This landed via
  [`application-surface-hardening-plan.md`](application-surface-hardening-plan.md).
  The remaining `fetch_bimi` work below is the *spec-correctness* half,
  which that change deliberately left untouched.

## Goals

- Make `fetch_bimi` a spec-correct, defensive proxy: extract the
  organizational domain via the Public Suffix List, parse TXT tags
  tolerantly, fetch and validate the SVG server-side against SVG Tiny
  PS, cache it in S3, and return a URL on infrastructure we control (or
  `null`).
- Bring the React admin app to parity with the shipped Apple display: a
  per-sender BIMI logo (or an initials fallback) to the left of each
  message-list row.
- Publish valid BIMI TXT records on every mail-bearing subdomain of
  every domain in `TF_VAR_MAIL_DOMAINS`, pointing at an SVG Tiny PS
  rendering of the Cabalmail mark derived from
  [`front-door/assets/cabalmail-mark.svg`](../../front-door/assets/cabalmail-mark.svg),
  hosted on the existing worldwide `front_door` CloudFront.

## Non-goals

- **VMC.** A Verified Mark Certificate (DigiCert, Entrust, ~$1500/yr)
  is required by Gmail for BIMI rendering but not by Apple Mail,
  Fastmail, Yahoo, or most other clients. Out of scope; see "Future
  work" below.
- **Non-SVG logo formats.** BIMI is SVG Tiny PS only; PNG/JPG fallbacks
  are not part of the spec and are not supported here.
- **Letter-glyph fallback SVGs.** Superseded by the natively drawn
  initials fallback already shipped on Apple (and adopted for React, see
  Phase B). No static glyph assets are produced.
- **Per-recipient or per-mailbox BIMI variants.** One mark per
  Cabalmail mail domain, applied via wildcard.

## Remaining `fetch_bimi` defects

[`lambda/api/fetch_bimi/function.py`](../../lambda/api/fetch_bimi/function.py),
after the DNS/exception hardening, still has the spec-correctness
defects below. The favicon fallback path is the whole tail of the file.

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
- **No SVG fetch or validation.** Returns the third-party URL verbatim
  to the client, which then loads attacker-controlled SVG directly.
  BIMI requires SVG Tiny PS; the spec is restrictive about what
  elements may appear, and a non-compliant SVG should not be rendered.
- **Favicon fallback is a guess.** `https://www.<lasttwo>/favicon.ico`
  may or may not exist; the path concatenates the last two labels of
  the sender domain regardless of whether that is the org domain.
- **No persistent caching.** API Gateway has a response cache, but
  per-domain DNS lookups and per-request SVG validation happen on every
  miss.

## Publishing infrastructure (reference)

- DKIM/SPF/DMARC are published by
  [`terraform/infra/modules/app/global_dns.tf`](../../terraform/infra/modules/app/global_dns.tf)
  and
  [`terraform/infra/modules/app/dmarc_user.tf`](../../terraform/infra/modules/app/dmarc_user.tf).
  DMARC is `p=reject` on the control domain, which qualifies the domain
  for BIMI.
- The admin CloudFront
  ([`terraform/infra/modules/app/cloudfront.tf`](../../terraform/infra/modules/app/cloudfront.tf))
  is `whitelist`-restricted to `US`. BIMI lookups come from receiving
  MTAs and clients worldwide, so the admin distribution is unsuitable
  for hosting any BIMI asset.
- The `front_door` site at `www.<control_domain>` is already worldwide
  ([`terraform/infra/modules/front_door/main.tf`](../../terraform/infra/modules/front_door/main.tf)
  sets `restriction_type = "none"`). Content ships through
  `.github/workflows/app.yml` -> `.github/scripts/render-front-door.py`
  -> `s3 sync s3://www.<control_domain>` plus a CloudFront
  invalidation. This is the right surface for the Cabalmail BIMI SVG.
- The handoff mark
  [`front-door/assets/cabalmail-mark.svg`](../../front-door/assets/cabalmail-mark.svg)
  is small, with no styles, scripts, gradients, or external refs - very
  close to SVG Tiny PS already. It needs `version="1.2"`,
  `baseProfile="tiny-ps"`, a `<title>` element, and an opaque
  background rectangle covering the viewBox.

## Phases

Each phase ships independently. Phase B (React) routes through stage per
CLAUDE.md; Phases A and C qualify as direct-to-prod-eligible (no data
plane impact, no user-facing surface change in isolation, no IAM
implications, purely additive).

### Phase A: spec-correct `fetch_bimi`

Goal: turn the Lambda into a defensive proxy that returns either a
validated SVG URL on infrastructure we control, or `null`. (DNS timeout
bounding and broad exception handling are already in place; do not
re-do them.)

- Add `publicsuffixlist` (or `tldextract`) to
  [`lambda/api/fetch_bimi/requirements.txt`](../../lambda/api/fetch_bimi/requirements.txt).
  Extract the organizational domain from the sender domain before any
  DNS query.
- Query `default._bimi.<org_domain>` exactly once. If `NXDOMAIN` /
  `NoAnswer`, return `{ "url": null }`. Do not walk superdomains.
- Parse the TXT record by splitting on `;`, trimming, and tokenizing
  each `key=value` pair. Require `v=BIMI1`. Extract `l=` by name.
  Ignore unknown tags. Reject records missing `l=`.
- Fetch the SVG with a 5 s timeout and a 32 KB response size cap.
  Reject larger payloads.
- Validate the SVG: parses as well-formed XML, root element is `<svg>`
  with `baseProfile="tiny-ps"`, no `<script>` anywhere, no `xlink:href`
  referring to anything off-document, no `<foreignObject>`, no
  `<image>` with external `href`. Reject otherwise.
- Cache validated SVGs to a new S3 bucket `bimi-cache.<control_domain>`
  (or a prefix on the existing admin bucket, if simpler) keyed by org
  domain, with a 24 h TTL set via S3 object metadata and a Lambda-side
  timestamp check on each request. Return the public HTTPS URL of the
  cached object.
- Drop the favicon fallback entirely. The client decides what to render
  when the URL is `null`.

Unit tests in `lambda/api/fetch_bimi/` cover:

- Valid record with `v=BIMI1; l=<url>`.
- Reordered tags (`a=` before `l=`).
- Missing `v=BIMI1`.
- `NXDOMAIN`, `NoAnswer`.
- Oversized SVG (33 KB).
- SVG containing `<script>`.
- Malformed XML.
- Subdomain with no record, org domain with a record (should it fall
  back to org? Spec says yes for *some* subdomains; document decision
  in the test).

### Phase B: React client display

Goal: parity with the shipped Apple `AvatarView` - a BIMI logo, falling
back to a natively drawn initials avatar, in the `Envelope.jsx` leading
slot. Mirror the Apple precedence and fallback rather than reintroducing
glyph SVGs; the unread dot stays.

- Add an initials/derivation utility under `react/admin/src/utils/`
  matching Apple's `AvatarView.initials`: take up to two initials from a
  non-empty display name, else the first letter of the local-part, else
  `?`. Unit tests cover those cases.
- Add a `useBimiUrl(senderDomain)` hook (or extend the existing
  envelope-list state) that calls `ApiClient.getBimiUrl` once per domain
  per session and memoizes results in component-tree state. Coalesce
  concurrent calls for the same domain. Caching a `null` (no record /
  failed lookup) result, like `BimiUrlCache` does, avoids re-fetching.
- In
  [`Envelope.jsx`](../../react/admin/src/Email/Messages/Envelope.jsx),
  render in the `envelope-leading` span: if `bimi.url` is a non-null
  string, an `<img>` (~24 x 24 px) with `src={bimi.url}`; otherwise the
  initials avatar. Keep the existing unread dot and selection checkbox.
- Update `Envelope.test.jsx`, `Envelopes.test.jsx`, and the viewport
  tests in `Messages.viewport.test.jsx` to cover the new slot.

### Phase C: publish BIMI for Cabalmail domains

Goal: every domain in `TF_VAR_MAIL_DOMAINS` publishes a working
`default._bimi` record pointing at the Cabalmail mark.

- Adjust the handoff mark into SVG Tiny PS form:
  - Add `version="1.2"` and `baseProfile="tiny-ps"` on the root.
  - Add `<title>Cabalmail</title>` as the first child of the root.
  - Add an opaque background `<rect>` covering the viewBox in
    `--cm-cream` (`#F4EBD6`).
  - Strip any `&#xA;` whitespace artifacts from the path data.
  - Save at `front-door/assets/bimi/cabalmail.svg`. Ships through the
    existing front_door pipeline.
- Add Terraform records. Pattern follows
  [`terraform/infra/modules/app/dmarc_user.tf`](../../terraform/infra/modules/app/dmarc_user.tf).
  Create them either in a new `bimi.tf` inside the `app` module or in a
  small dedicated `bimi` module - whichever keeps the
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
  vantage points shows the wildcard not being honored, switch to an
  explicit list driven by a new variable
  `var.bimi_subdomains = ["mail-admin", ...]` and iterate. The wildcard
  is the preferred starting point.
- After apply, validate with
  [bimigroup.org/bimi-inspector](https://bimigroup.org/bimi-inspector)
  for a known sender subdomain. Once verified, document the inspector
  URL and `dig` commands in [`docs/operations.md`](../operations.md).

## Verification

Each phase verifies end-to-end before merging.

- **Phase A.** `cd lambda/api/fetch_bimi && python -m pytest` against
  the new tests. Smoke-test in stage by hitting
  `/fetch_bimi?sender_domain=cnn.com`, `/fetch_bimi?sender_domain=google.com`,
  and a domain known to have no BIMI; observe `url` is a non-null
  S3-backed URL in the first two cases and `null` in the third.
- **Phase B.** `cd react/admin && npm run test`. Manually load the
  admin app, confirm logos render for messages from known
  BIMI-publishing senders and initials avatars render for the rest.
- **Phase C.** From outside the Cabalmail VPC,
  `dig TXT default._bimi.<some-mail-subdomain>.<cabalmail-domain>`
  returns the expected record. Send a test email from a Cabalmail
  address to a Gmail account and a Fastmail account; confirm the
  Cabalmail mark renders (Gmail will require a VMC, so the mark appears
  in Fastmail but not Gmail - that is expected and matches the "VMC
  deferred" non-goal).

## Future work

- **VMC.** Once the rest of the pipeline is solid, a Verified Mark
  Certificate from DigiCert or Entrust (~$1500/yr) unlocks BIMI display
  in Gmail. The change at our end is one tag added to each TXT record:
  `a=https://www.<control_domain>/assets/bimi/cabalmail.pem`, with the
  certificate file hosted alongside the SVG. The certificate itself is
  the cost; the wiring is trivial.

## Rollout notes

- Phase A (Lambda) and Phase C (Terraform TXT records plus front_door
  SVG) are direct-to-prod-eligible per the "Direct-to-prod scaffolding"
  rules in [`CLAUDE.md`](../../CLAUDE.md): no data plane impact, no
  user-facing surface change in isolation, no IAM/security implications,
  purely additive.
- Phase B (React) is a user-facing UI change and routes via stage as
  usual.

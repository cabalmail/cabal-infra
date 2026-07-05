# Inbound Auth Verification Plan

## Context

The smtp-in tier is a pure relay. It accepts mail for hosted domains from the
internet, routes it to the imap tier via mailertable, and performs **no**
SPF, DKIM, or DMARC verification — [`docker/templates/in-sendmail.mc`](../../docker/templates/in-sendmail.mc)
declares no `INPUT_MAIL_FILTER` at all. Meanwhile we hold *senders* to a
strict standard: the control domain publishes `p=reject` with full
SPF/DKIM/DMARC ([`terraform/infra/modules/app/global_dns.tf`](../../terraform/infra/modules/app/global_dns.tf)),
and we ingest the aggregate reports other receivers send us
(`lambda/api/process_dmarc`). We evaluate nothing in the other direction: a
message claiming to be from `paypal.com` that fails every authentication
check is delivered to the user's inbox looking identical to one that passes.

This plan adds verification milters to smtp-in that evaluate SPF, DKIM, and
DMARC on every inbound message and stamp the result as an
`Authentication-Results` header (RFC 8601), then surfaces that result to the
end user in the webmail and Apple clients. **Verification is observe-only:
no message is rejected, quarantined, or rerouted based on the result,
regardless of the sender's published policy.** The user sees the finding and
decides. This is deliberate — a small personal MX misclassifying one real
message costs more than a hundred correctly-flagged spoofs are worth.

The stamped results are also the foundation for outbound DMARC aggregate
report generation (reporting to *other* domains on how their mail
authenticated here), which is scoped separately in
[`docs/tentative/dmarc-outbound-reports-plan.md`](../tentative/dmarc-outbound-reports-plan.md).
That plan depends on this one; this one does not depend on it.

Four phases, strictly additive and independently shippable:

1. **Verification milters on smtp-in.** OpenDKIM in verify-only mode plus
   OpenDMARC in monitor mode (with its built-in SPF evaluation), stamping
   `Authentication-Results` under our authserv-id. Includes stripping
   forged inbound `Authentication-Results` headers that claim our
   authserv-id.
2. **Lambda envelope surface.** Fetch and parse the header in
   `envelope_dict()` and expose a compact `auth_results` field to both
   clients.
3. **React display.** Failure indicator in the envelope row, per-method
   breakdown in the message reading view.
4. **Apple display.** Same, through `ApiEnvelope` → `Envelope` →
   detail view.

## Goals

- Every message arriving through smtp-in carries an
  `Authentication-Results` header with SPF, DKIM, and DMARC verdicts,
  stamped under the control-domain authserv-id.
- A forged `Authentication-Results` header presented by the connecting
  client cannot survive to the mailbox claiming our authserv-id.
- The envelope payload exposes the parsed verdicts; both clients render
  them, with a visible warning on DMARC failure and an honest
  "not verified" state for mail that predates the feature or bypassed
  smtp-in.
- Zero change to mail acceptance: no new 4xx/5xx paths, no reordering or
  delay beyond milter latency.

## Non-goals

- **Rejecting or quarantining mail.** Even `p=reject` senders get
  delivered. Enforcement can be revisited once we have months of
  observe-only data; it is out of scope here.
- Spam scoring, content filtering, or reputation lookups (no
  SpamAssassin, no RBLs).
- ARC (RFC 8617) sealing or validation. Forwarded mail will often fail
  SPF and sometimes DMARC; the UI copy should avoid implying "fail" means
  "malicious".
- Verifying mail that does not transit smtp-in (locally-originated mail
  routed from smtp-out to the imap tier). It renders as "not verified".
- Outbound aggregate report generation — see the tentative plan linked
  above.

## Current state

- [`docker/templates/in-sendmail.mc`](../../docker/templates/in-sendmail.mc):
  features are `always_add_domain`, `nouucp`, `genericstable`,
  `mailertable`, `access_db`, `greet_pause`, `blacklist_recipients`,
  `no_default_msa`. No milters. AUTH was deliberately removed in phase 5
  of [`container-runtime-hardening-plan.md`](./container-runtime-hardening-plan.md).
- [`docker/smtp-in/Dockerfile`](../../docker/smtp-in/Dockerfile): installs
  sendmail, procmail, rsyslog, awscli, supervisor. No OpenDKIM/OpenDMARC.
- The milter precedent lives on smtp-out:
  `INPUT_MAIL_FILTER('opendkim', 'S=inet:8891@localhost')` in
  [`docker/templates/out-sendmail.mc`](../../docker/templates/out-sendmail.mc),
  configured by
  [`docker/smtp-out/configs/opendkim.conf`](../../docker/smtp-out/configs/opendkim.conf)
  (`Mode sv`, loopback-only `TrustedHosts` per hardening phase 5),
  supervised alongside sendmail in
  [`docker/smtp-out/supervisord.conf`](../../docker/smtp-out/supervisord.conf).
- The envelope pipeline fetches a fixed header set:
  `ENVELOPE_HEADER_FIELDS_KEY = 'BODY[HEADER.FIELDS (X-PRIORITY REFERENCES)]'`
  ([`lambda/api/_shared/helper.py:901`](../../lambda/api/_shared/helper.py)),
  and `envelope_dict()` (helper.py:929) builds the JSON both clients
  consume: `id`, `date`, `subject`, `from`, `to`, `cc`, `flags`, `struct`,
  `priority`, `message_id`, `in_reply_to`, `references`. The threading
  fields (0.10.x) are the model for adding a new field end to end.
- `fetch_message` already hands clients a presigned URL to the raw RFC 822
  message; the React `ViewSourceModal` parses and displays all headers, so
  the full `Authentication-Results` text is inspectable today once
  stamped — this plan is about *default-UI* surfacing.
- No `Authentication-Results` handling exists anywhere in the codebase.
  The only DMARC code is the admin-side aggregate-report ingest.

## Design

### Verification must run on smtp-in

SPF evaluation needs the connecting client's IP, HELO name, and envelope
sender. Only smtp-in sees the internet peer; by the time the imap tier
receives the message the peer is smtp-in itself. DKIM and DMARC could
technically run anywhere, but they belong beside SPF so a single milter
pass produces one coherent header.

### Milter stack

Two milters, chained in declaration order in `in-sendmail.mc`:

```
INPUT_MAIL_FILTER(`opendkim', `S=inet:8891@localhost, F=T, T=R:2m')dnl
INPUT_MAIL_FILTER(`opendmarc', `S=inet:8893@localhost, F=T, T=R:2m')dnl
```

- **OpenDKIM, verify-only** (`Mode v`). No KeyTable/SigningTable — verify
  mode checks signatures against the sender's published DNS keys and needs
  no per-domain generated config, so `generate-config.sh` is untouched.
  Stamps `Authentication-Results` with the `dkim=` verdict.
- **OpenDMARC, monitor mode** (`RejectFailures false`,
  `SPFSelfValidate true`). Runs after OpenDKIM, reads its
  `Authentication-Results`, performs its own SPF check, evaluates the
  sender's published DMARC policy including alignment, and appends the
  `spf=` and `dmarc=` verdicts. Monitor mode never rejects; the milter's
  verdict is `accept` for every disposition.
- Both configured with `AuthservID` set to the control domain (rendered
  from `__CERT_DOMAIN__` the same way the sendmail template is), so one
  stable, spoof-checkable identifier appears in the header.
- `F=T` (temp-fail on milter outage) is the deliberate choice over `F=`
  (accept unfiltered): if the milters are down, mail queues at the sender
  and retries, rather than a window of unstamped mail that renders as
  "not verified". Sendmail's 4xx here is safe — real MTAs retry for days.

DNS resolution uses the VPC resolver as everything else does; on stage,
DNSSEC validation (docs/dnssec.md) already covers these lookups.

### Header hygiene: forged Authentication-Results

Anyone can send a message that already contains
`Authentication-Results: <control-domain>; dmarc=pass ...`. If that header
survives to the mailbox, the Lambda parser and both clients would show a
spoofed pass. The milter stage must therefore strip inbound
`Authentication-Results` headers before stamping. OpenDKIM's
`RemoveARFrom` (scoped to all external hosts) is the intended mechanism —
confirm the exact knob and semantics against the packaged version during
implementation; if it proves insufficient, a two-line header check in the
sendmail config or a formail pass at local delivery are the fallbacks.
The Lambda parser additionally only trusts headers whose authserv-id
matches the control domain exactly, as defense in depth.

### The `auth_results` envelope field

`envelope_dict()` gains:

```json
"auth_results": {"spf": "pass", "dkim": "pass", "dmarc": "fail"}
```

- Parsed server-side once, in helper.py, from the first
  `Authentication-Results` header bearing the trusted authserv-id; both
  clients get identical, pre-digested verdicts.
- Values are the RFC 8601 result tokens as-is (`pass`, `fail`, `none`,
  `neutral`, `softfail`, `temperror`, `permerror`, `policy`). Clients
  bucket them (ok / warn / unknown) rather than the Lambda deciding
  presentation.
- Key absent per method = method not evaluated. Whole field absent or
  `null` = no trusted header on the message (old mail, internal mail).
  **Absent must never render as pass.**
- Parsing is a small stdlib affair (split on `;`, `method=result` pairs);
  no new dependency in the per-function bundles.

The IMAP fetch constant becomes:

```python
ENVELOPE_HEADER_FIELDS_KEY = 'BODY[HEADER.FIELDS (X-PRIORITY REFERENCES AUTHENTICATION-RESULTS)]'
```

`fetch_message` needs no change: the reading view receives the envelope,
and the raw source view already exposes the full header text.

### Client display

Three states everywhere: **verified-ok** (dmarc pass), **warning** (dmarc
fail/permerror, or dmarc absent with spf and dkim both fail), and
**not verified** (no data — the quiet default for pre-feature and internal
mail). Copy for the warning state says the message *could not be
authenticated as coming from its claimed sender* — not "dangerous" — since
forwarding legitimately breaks these checks.

- **React envelope row**
  ([`react/admin/src/Email/Messages/Envelope.jsx`](../../react/admin/src/Email/Messages/Envelope.jsx)):
  add a warning icon to the existing `envelope-indicators` block (beside
  important/paperclip/reply/star) for the warning state only. Pass and
  not-verified show nothing in the list — the row's footprint stays
  stable and the indicator area already varies by flags.
- **React reading view**
  ([`react/admin/src/Email/MessageOverlay/index.jsx`](../../react/admin/src/Email/MessageOverlay/index.jsx)):
  a compact authentication line in the header area with per-method chips
  (SPF / DKIM / DMARC, each colored by verdict), shown in all three
  states ("Not verified" renders muted). Links to the existing view-source
  modal for the full header.
- **Apple**: `ApiEnvelope`
  ([`apple/CabalmailKit/Sources/CabalmailKit/API/ApiClientTypes.swift`](../../apple/CabalmailKit/Sources/CabalmailKit/API/ApiClientTypes.swift))
  gains an optional `authResults` decoded with `decodeIfPresent` (the
  `isImportant` pattern); `Envelope`
  ([`apple/CabalmailKit/Sources/CabalmailKit/Models/Envelope.swift`](../../apple/CabalmailKit/Sources/CabalmailKit/Models/Envelope.swift))
  carries it; `makeEnvelope(_:)` in `ApiBackedImapClient` maps it. List
  row shows the warning-state icon; `MessageDetailView` shows the chips.
  Old clients ignore the extra JSON field; new clients treat absence as
  not-verified — deployable in either order.

## Phase 1 — Verification milters on smtp-in

- `docker/smtp-in/Dockerfile`: install `opendkim` and `opendmarc` (see
  open questions on opendmarc packaging), `COPY` the two milter configs.
- New `docker/smtp-in/configs/opendkim-verify.conf` (`Mode v`,
  `Socket inet:8891@localhost`, `AuthservID __CERT_DOMAIN__`,
  AR-stripping per header-hygiene section) and
  `docker/smtp-in/configs/opendmarc.conf` (`RejectFailures false`,
  `SPFSelfValidate true`, `Socket inet:8893@localhost`,
  `AuthservID __CERT_DOMAIN__`, `IgnoreHosts` loopback). Placeholder
  rendering in `entrypoint.sh`, same as the sendmail template.
- `docker/templates/in-sendmail.mc`: the two `INPUT_MAIL_FILTER` lines,
  with a comment block explaining observe-only intent, in house style.
- `docker/smtp-in/supervisord.conf`: two new supervised programs, started
  before sendmail.
- CI: new `COPY` sources must be added to the `docker_smtp-in` path filter
  in `app.yml` — `check-docker-tier-filters.sh` enforces this.
- No task-definition change (no new env vars, ports, or volumes), so no
  revision-marker bump needed.

**Verify:** send from a well-configured external sender (Gmail) and from a
deliberately misaligned one; confirm stamped verdicts in the delivered
message source and in maillog on CloudWatch. Send a message pre-loaded
with a forged `Authentication-Results` header claiming the control domain;
confirm it is stripped. Confirm delivery latency is unchanged to within
milter noise and no message is rejected.

## Phase 2 — Lambda envelope surface

- helper.py: extend `ENVELOPE_HEADER_FIELDS_KEY`, add the trusted-parse
  helper, add `auth_results` to `envelope_dict()`. helper.py grows in
  place (it carries a scoped `too-many-lines` disable; do not split it).
- pylint clean; local `python -m function` smoke on `list_envelopes`.

**Verify:** envelopes for newly-delivered external mail carry
`auth_results`; pre-feature messages carry none; a message with only a
forged (untrusted-authserv-id) header parses as absent.

## Phase 3 — React display

- `Envelope.jsx` indicator, `MessageOverlay` chips, shared
  verdict-bucketing util, styles. Vitest coverage for the bucketing logic
  and the three states.

## Phase 4 — Apple display

- `ApiClientTypes.swift`, `Envelope.swift`, `ApiBackedImapClient.swift`
  mapping, list-row icon, `MessageDetailView` chips. Kit tests for
  decoding with the field present, absent, and partial
  (`swift test` in `apple/CabalmailKit`).

## Rollback

Each phase is independently revertible. Phase 1: remove the two
`INPUT_MAIL_FILTER` lines (and supervisord programs) and redeploy the
tier — mail flows exactly as today; already-stamped headers are inert.
Phases 2–4 are additive field/UI changes; clients already treat the field
as optional, so reverting any one layer strands nothing.

## Acceptance

- External mail shows correct verdicts in webmail and Apple clients;
  DMARC-failing mail shows the warning indicator in both list and reading
  views; it is still delivered.
- Forged AR headers cannot produce a pass.
- Pre-feature and smtp-out-originated mail shows "not verified", not pass.
- No change in inbound acceptance behavior; CI green across app, apple,
  and docker-filter checks.

## Open questions

- ~~Is `opendmarc` packaged for AL2023?~~ **Resolved (2026-07-05): it is
  not** (confirmed against the AL2023 core repo metadata; `opendkim`,
  `sendmail-milter-devel`, and the autotools chain are packaged; `libspf2`
  is not). The smtp-in image builds OpenDMARC from the pinned
  `rel-opendmarc-1-4-2` tag archive (checksum-verified; the project
  publishes no dist tarballs) in a Dockerfile builder stage, configured
  `--with-spf` for the internal SPF implementation, and copies the binary
  and library into the runtime image.
- Exact AR-stripping knob (`RemoveARFrom` scope semantics) on the packaged
  OpenDKIM version — verify before relying on it; fallbacks listed above.
- Whether the envelope-row indicator should also appear for the
  softfail/neutral middle ground, or only hard DMARC failure. Start with
  hard failure only; widen with observed data.

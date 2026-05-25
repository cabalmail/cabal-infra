# Application Surface Hardening Plan

## Context

The Lambda API surface (`lambda/api/*/function.py` + `lambda/api/_shared/helper.py`) has grown organically from the 0.2.x admin-app split. Each endpoint was added in isolation and inherits a thin slice of validation from upstream callers (the React admin app, the Apple client) rather than enforcing its own. That worked while the only client was the in-house React app and the only writers were the project owner; it does not generalise to "Cabalmail is now someone's primary mailbox" and "anyone with a Cognito account can issue raw IMAP-shaped requests."

This plan is the application-layer counterpart to [`iac-quality-gates-plan.md`](./iac-quality-gates-plan.md): scanners will catch the IaC posture, but Python code that calls `IMAPClient.search(raw_query)` with attacker-controlled input never lights up Checkov. The findings here are the result of an audit pass across every handler under `lambda/api/`. They cluster naturally into five themes, addressed in five phases. Each phase is a candidate PR or small PR set, independently shippable.

The themes:

1. **Inbound XML safety on `/process_dmarc`.** The DMARC report ingestor parses attacker-controlled XML/zip/gzip from arbitrary external senders with the stdlib `xml.etree.ElementTree` and no decompression cap. This is the single highest-leverage finding in the audit.
2. **Outbound message integrity on `/send`.** Header values are written straight into `EmailMessage` and the resulting object — `BCC` field and all — is `append()`-ed to the user's Outbox before SMTP submission, so every BCC recipient is permanently visible in Sent. Header injection via subject/from/in-reply-to/references is also poorly bounded.
3. **Input validation on the IMAP-shaped endpoints** (`/search`, `/list_messages`, `/set_flag`, `/move_messages`, `/list_envelopes`, `/fetch_inline_image`). Folder names, flag tokens, UIDs, sort criteria, search expressions, and S3-keyed indices flow from query strings and bodies into IMAP commands and S3 keys with no whitelist. Most are not exploitable today because the IMAP master-user model scopes operations to the caller's mailbox, but they are footguns one shape change away from real bugs.
4. **DNS-touching endpoints** (`/new`, `/revoke`, `/new_address_admin`, `/repair_dns_record`, `/check_dns_record`, `/fetch_bimi`). Subdomain and apex names from the request body flow into Route 53 `ChangeResourceRecordSets` calls and `dns.resolver` queries with neither shape validation nor a server-side guard that the zone-ID-to-domain mapping actually matches.
5. **Per-endpoint abuse limits.** API Gateway's global throttle (100/50 rps) is the only rate limit. Admin-only mutations (`/delete_user`, `/disable_user`, `/enable_user`, `/set_user_domain_access`) have no per-caller ceiling. `/process_dmarc` and `/list` do unbounded DynamoDB scans. The pre-signed `/upload_url` window is 10 minutes — generous for the attacker if the URL leaks.

## Goals

- A malformed or malicious DMARC report — XXE payload, billion-laughs, zip bomb, gzip bomb, or unsolicited XML from an arbitrary sender — cannot read local files, exhaust Lambda memory, or pollute the `cabal-dmarc-reports` table.
- The Sent folder for any user contains, for every message they sent, exactly the same headers any RFC-compliant MUA would record: no `Bcc:` line, no caller-supplied `From:` that disagrees with the envelope sender, no CRLF-smuggled extra headers.
- IMAP-shaped handlers reject malformed input at the API boundary (4xx) rather than relaying it into Dovecot and letting the IMAP server decide.
- DNS-touching endpoints validate every subdomain and apex against the configured `DOMAINS` allowlist *and* re-verify the zone-ID-to-domain mapping at runtime so a misconfigured env var cannot cause cross-zone writes.
- Admin mutations are per-caller-rate-limited with audit logging; abuse of a compromised admin account is bounded to a small number of changes before alerts fire.
- Every handler explicitly catches `json.JSONDecodeError` and returns a 400 with a sanitized message rather than a 500 with a Python traceback.

## Non-goals

- Replacing API Gateway with something else (App Runner, ALB+Lambda, etc.).
- A general WAF rollout on top of API Gateway (covered as a follow-up in [`identity-iam-hardening-plan.md`](./identity-iam-hardening-plan.md)).
- Re-architecting the master-user IMAP model. The model is sound; the audit findings are about input handling above it, not the authentication model.
- Adding a separate "DMARC operator" account or pre-filter SMTP service. The hardening here keeps `/process_dmarc` as the single ingest path and makes it safe to keep that posture.
- Building a structured IMAP search-expression parser to replace `client.search(raw_query)`. Scope-bounded today; revisit only if real abuse signals appear.
- Per-user IMAP session pooling. Out of scope here; covered in [`large-mailbox-hardening-plan.md`](./large-mailbox-hardening-plan.md) Phase 7.

## Current state (audit)

### Inbound XML — `/process_dmarc`

- Parser: [`parse_dmarc_xml`](../../lambda/api/process_dmarc/function.py) uses `xml.etree.ElementTree.fromstring(xml_data)` directly. Stdlib ElementTree disables some external-entity processing by default but is explicitly documented as not safe against untrusted XML; the Python docs recommend `defusedxml`.
- Decompression: [`extract_xml_from_attachment`](../../lambda/api/process_dmarc/function.py) calls `zf.read(name)` and `gzip.decompress(payload)` with no size ceiling. A 10 KB zip-bombed `.xml.gz` decompresses to gigabytes and is fed verbatim into the parser.
- Sender filter: the handler walks every message in the dmarc@ mailbox and treats every `.zip`/`.gz`/`<?xml`-shaped attachment as a candidate report. There is no `From:` allowlist of known report senders (Google, Microsoft, Yahoo, etc.). Anyone on the internet can email the address and have their payload parsed.
- Storage: parsed records are written to the `cabal-dmarc-reports` DynamoDB table with no schema validation beyond what `_parse_record` reads. A spoofed report can pollute the table with fabricated `source_ip`/`disposition`/`org_name` fields.

### Outbound message integrity — `/send`

- Sender authorisation: [`user_authorized_for_sender`](../../lambda/api/_shared/helper.py:62) checks that `body['sender']` is owned by the calling user; that part is correct.
- Header construction: [`compose_message`](../../lambda/api/send/function.py:136) writes `subject`, `from`, `to`, `cc`, **`bcc`**, `message_id`, `in_reply_to`, `references` straight into `EmailMessage` via item-assignment. `EmailMessage` does fold long headers but applies only minimal validation; embedded CR/LF in `subject`/`message_id`/`references` is silently encoded in some cases and silently accepted in others.
- BCC retention: the composed `msg` is serialised by `msg.as_string()` and `client.append('Outbox', ...)` in [`append_outbox`](../../lambda/api/send/function.py:165). The append preserves `Bcc:`. The message is then `move`-d into `Sent` after SMTP submission. BCC recipients are visible to anyone who can read Sent — which includes the user, anyone they delegate Sent access to in the future, and any backup or admin path that reads Maildir directly.
- From spoofing: `msg['From']` is set to `body['sender']` (validated). The SMTP envelope sender is whatever `smtplib.send_message` derives from the message — by default, the `From:` header. No defence against display-name games where `From: "Real Person <victim@apex>" <sender@subdomain>` parses one way to spam filters and another way to humans.
- Attachments: the s3_key shape is checked by `_KEY_SHAPE = ^outbound/([^/]+)/[^/]+/[^/]+$` and the user segment is verified. Good. The presigned URL TTL is 600 seconds (`upload_url/function.py`), which is longer than necessary.

### IMAP-shaped handlers

- [`list_messages/function.py`](../../lambda/api/list_messages/function.py) reads `sort_field` and `sort_order` from the query string and passes both directly to `IMAPClient.sort(...)`. RFC 5256 defines a fixed set of valid criteria; anything else triggers a protocol error.
- [`set_flag/function.py`](../../lambda/api/set_flag/function.py) reads `body['flag']` and passes it to `add_flags`/`remove_flags` with no whitelist. Custom keywords are valid IMAP but unbounded keyword usage in user mailboxes is a slow-leak DoS.
- [`move_messages/function.py`](../../lambda/api/move_messages/function.py) reads `source` and `destination` folder names, normalises `/`→`.`, and trusts the rest. Path-like or quote-bearing folder names are silently accepted.
- [`search/function.py`](../../lambda/api/search/function.py) passes the raw query string to `client.search(raw_query)`. The IMAPClient library does protect against some shapes but the surface is large; an attacker-controlled query can be made arbitrarily expensive (`OR (OR (OR ...))` nesting).
- [`fetch_inline_image/function.py`](../../lambda/api/fetch_inline_image/function.py) composes an S3 key as `f"{user}/{folder}/{id}/{index}"`. `index` comes straight from the query string; while S3 treats `/` as opaque, attacker-controlled fragments make it harder to reason about cache invalidation and audit.
- Most handlers do `json.loads(event['body'])` with no try/except; a malformed body yields a 500 with a Python traceback in the response.

### DNS-touching endpoints

- [`new/function.py:36`](../../lambda/api/new/function.py) and [`revoke/function.py`](../../lambda/api/revoke/function.py) compose record names as `f'_dmarc.{subdomain}.{tld}'` and call `route53.change_resource_record_sets(HostedZoneId=domains[tld], ...)`. `domains` is a JSON dict from the `DOMAINS` env var. Subdomain shape is not validated.
- `domains[tld]` raises `KeyError` if `tld` is not in the env-supplied dict; the resulting 500 is fine. The deeper concern is that the env var is trusted to map `tld` → `zone_id`. If the env var drifts (operator typo, half-applied Terraform, region mismatch), changes go to the wrong zone with no runtime safety net.
- [`fetch_bimi/function.py`](../../lambda/api/fetch_bimi/function.py) takes `sender_domain` from the query string and passes it unvalidated to `dns.resolver.query(f'default._bimi.{sender_domain}', 'TXT')`. The dnspython call has no `lifetime=`; a slow auth NS for the queried domain blocks the Lambda for the full timeout.

### Per-endpoint abuse limits

- API Gateway stage settings (`terraform/infra/modules/app/main.tf:142-143`) set `throttling_rate_limit = 100`, `throttling_burst_limit = 50`. Stage-wide. No per-endpoint, no per-caller.
- [`list/function.py`](../../lambda/api/list/function.py) and [`revoke/function.py`](../../lambda/api/revoke/function.py) call `cabal_addresses.scan(FilterExpression=...)` — full-table scan plus client-side filter. Cost scales with table size, not result-set size.
- `/process_dmarc` walks every message in the inbox per invocation. No `--limit`, no batching.
- `/upload_url` PUT presigned URLs default to 600 s and there is no per-user ceiling on concurrent active URLs.

## Target state

### Phase 1 — DMARC XML safety

- Replace `import xml.etree.ElementTree as ET` with `import defusedxml.ElementTree as ET` in [`process_dmarc/function.py`](../../lambda/api/process_dmarc/function.py) and add `defusedxml>=0.7` to its `requirements.txt`. `defusedxml` is a near-drop-in replacement that disables external entities, DTD processing, and entity expansion bombs.
- Cap decompressed payload size at a fixed ceiling (start at 50 MB — generous for any real DMARC aggregate report, which are typically under 1 MB compressed and 5-10 MB uncompressed). Read zip entries via `zf.open(name).read(MAX_BYTES + 1)` and reject if the result exceeds `MAX_BYTES`. For gzip, wrap `gzip.GzipFile` and call `.read(MAX_BYTES + 1)` with the same check rather than `gzip.decompress(payload)`.
- Cap raw inbound message size at 25 MB (`/process_dmarc` fetches via IMAP `FETCH`; abort if the part-size exceeds the cap before downloading).
- Cap messages-per-invocation at a small fixed number (start at 50). The handler is scheduled and idempotent; one invocation does not have to drain the inbox.
- Add a sender allowlist: a comma-separated list of allowed `From:` domains in an env var (`DMARC_REPORT_SENDERS=google.com,microsoft.com,yahoo-inc.com,...`). Messages from senders outside the allowlist are skipped (not bounced — silently ignored, since legitimate-but-unknown senders should not be punished, just not parsed).
- Drop the empty-result-set fast path that today swallows zip-extraction errors as "no XML found." Replace with a categorised result so we can alarm on `xml_parse_errors` separately from `no_attachment` and `unknown_sender`.

### Phase 2 — Outbound message integrity (`/send`)

- Strip `Bcc:` from the message before `client.append('Outbox', msg.as_string().encode())`. Two acceptable shapes:
  1. Compose two messages — one with BCC for SMTP submission, one without for the Outbox append. Lower risk; mirrors what real MUAs do.
  2. Compose one message, delete `Bcc:` after SMTP submission and before append. Avoids the SMTP-vs-IMAP envelope-drift concern but relies on `del msg['Bcc']` being unambiguous.
  Recommendation: shape (1).
- Validate `subject`, `message_id`, `in_reply_to`, every entry in `references`, and the display-name portion of `to`/`cc`/`bcc` for absence of `\r` and `\n` before assignment. Reject with 400 if present. Python's `email.policy.SMTP` already does this for some fields; explicit validation makes the contract clear and catches edges the policy misses.
- Constrain `body['sender']` to the *exact* address `user_authorized_for_sender` validated, and use that exact string as the SMTP `MAIL FROM` (`smtp_client.send_message(msg, from_addr=sender, to_addrs=...)`). This prevents display-name games that leave `From:` parsing ambiguous.
- Cap attachments at 10 per message (the React UI never sends more). Cap total decoded attachment bytes at the existing `MAX_TOTAL_ATTACHMENT_BYTES = 25 MiB` (already in place) — the new bound is on count.
- Shorten the `/upload_url` presigned PUT TTL from 600 s to 120 s. The React client submits within a few seconds of mint; 120 s is generous for that flow and tighter for any leak.

### Phase 3 — IMAP-shaped endpoint validation

A small shared validator in [`_shared/helper.py`](../../lambda/api/_shared/helper.py), used by every IMAP-shaped handler:

- `validate_folder_name(name) -> str | raises ValueError` — case-preserving, requires `^[A-Za-z0-9 _\-./]+$`, rejects empty, length-capped at 255 bytes.
- `validate_uid_list(ids) -> list[int]` — every entry parseable as an int in `[1, 2**32 - 1]`, list length capped at the chunking ceiling from [`large-mailbox-hardening-plan.md`](./large-mailbox-hardening-plan.md) (Phase 2 of that plan introduces `MAX_IDS_PER_REQUEST = 5000`; reuse it here).
- `validate_flag(flag) -> str` — must be a known system flag (`\Seen`, `\Answered`, `\Flagged`, `\Deleted`, `\Draft`) or a custom keyword matching `^[A-Za-z0-9_\-]+$` of length ≤ 64.
- `validate_sort_criterion(field, order) -> tuple[str, str]` — `field ∈ {ARRIVAL, CC, DATE, FROM, SIZE, SUBJECT, TO}`, `order ∈ {ASC, DESC}` (the latter mapped to a `REVERSE` prefix at the call site).
- `validate_search_query(raw) -> str` — IMAP search syntax is non-trivial; the validator at minimum rejects unmatched parens, NUL bytes, and any byte outside ASCII-printable + `\t`. Length-capped at 8 KB.
- `validate_safe_path_component(s) -> str` — for `fetch_inline_image`'s `index`. `^[A-Za-z0-9_\-.@]+$`, length ≤ 128. Same validator usable for any future S3-key-fragment input.

Every handler catches `ValueError` from these validators and returns a 400 with `{"status": "Invalid input: <message>"}`. Every handler also catches `json.JSONDecodeError` around `json.loads(event['body'])` and returns 400.

### Phase 4 — DNS-touching endpoint hardening

- Add `validate_dns_label(s)` and `validate_dns_apex(s)` helpers (`[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?` per label; apex resolves to at least two labels). Used by `/new`, `/revoke`, `/new_address_admin`, `/repair_dns_record`, `/check_dns_record`.
- Runtime zone verification: before calling `route53.change_resource_record_sets`, look up the zone via `route53.get_hosted_zone(Id=zone_id)` and verify `Name` matches `tld + '.'`. Cache the verification result per cold start to keep cost constant. Mismatch → refuse the request and emit a `WARN`-level log line for alerting.
- Constrain `fetch_bimi`'s `sender_domain` via `validate_dns_apex`. Set a 5-second total DNS-lookup budget: `resolver = dns.resolver.Resolver(); resolver.lifetime = 5; resolver.timeout = 2`.

### Phase 5 — Per-endpoint abuse limits

- Admin mutations (`/delete_user`, `/disable_user`, `/enable_user`, `/set_user_domain_access`, `/new_address_admin`) gain a per-caller token bucket implemented against a small DynamoDB counter table (`cabal-rate-limits`, TTL 1 hour) or — simpler — a Cognito client-app usage-plan in API Gateway with an `x-api-key`-by-cognito-username binding. Recommendation: start with DynamoDB; revisit if the table contention becomes measurable. Ceiling: 30 mutations per minute per caller.
- Audit log: every admin mutation emits a structured JSON log line with `caller`, `action`, `target`, `outcome`. CloudWatch Logs Insights query in the runbook. Optional: pipe to a separate `audit` log group via `subscription_filter` for longer retention. Out of scope for the first ship.
- Replace the `cabal-addresses.scan(FilterExpression=...)` in `/list` with a `cabal-addresses.query` against a new GSI `(user, address)` so the cost is O(addresses-owned), not O(table).
- The `/process_dmarc` per-invocation message ceiling from Phase 1 also counts toward this theme.
- The `/upload_url` TTL change from Phase 2 also counts toward this theme.

## Migration sequence

Each phase is one PR (or a small PR set) and is independently reversible.

### Phase 1 — DMARC XML safety

Single PR. Touches only `lambda/api/process_dmarc/`. New env var `DMARC_REPORT_SENDERS` plumbed through Terraform (`terraform/infra/modules/app/dmarc.tf`) with a sensible default ("google.com,microsoft.com,yahoo-inc.com,fastmail.com,protonmail.com,mailchimp.com,emarsys.net" — extend as we observe legit senders in CloudWatch over the first week).

Rollback: revert the PR. Pre-existing reports already in `cabal-dmarc-reports` are unaffected — the parser change is forward-only.

### Phase 2 — `/send` BCC removal + header validation

Single PR. Touches `lambda/api/send/function.py` and `lambda/api/upload_url/function.py`. No env var changes. No data migration.

Verification: send a test email with To+Cc+Bcc to a sinkhole address; confirm the resulting Sent-folder copy has no `Bcc:` header but the SMTP recipients list includes the BCC entry.

Rollback: revert the PR. No state to undo.

### Phase 3 — IMAP-shaped endpoint validation

One PR for the shared validator in `_shared/helper.py`. Then one PR per affected handler (six handlers, six PRs) so each is independently revertable and the rollout can pause mid-stream if a validator turns out to be too strict.

Rollback per handler: revert the handler PR; the validator stays in `helper.py` unused. Revert the validator PR last only if all six handler PRs are reverted.

### Phase 4 — DNS-touching endpoint hardening

Single PR. Touches `_shared/helper.py` (validators) and the five DNS-touching handlers. Adds a `_zone_cache` module-level dict in `helper.py` for the runtime verification cache.

Rollback: revert the PR. The zone-name verification is purely additive — pre-existing zones are not modified.

### Phase 5 — Per-endpoint abuse limits

Smaller PR sequence:

1. Audit-log structured emission (no enforcement, only logging). One PR.
2. Rate-limit table + helper. One PR; adds `cabal-rate-limits` DynamoDB table in Terraform.
3. Per-admin-mutation rate-limit gating. One PR per handler family (admin user-mgmt, admin domain-access). Two PRs.
4. `/list` migration to query-against-GSI. Requires a one-time backfill from `scan` → write missing GSI keys; ship the GSI add as a separate apply before the handler PR.

Rollback per PR: revert. The rate-limit table can stay (cheap, on-demand billing); the handlers stop reading from it.

## Risks and trade-offs

- **`defusedxml` is a new dependency.** Audited and widely used (it ships in Python's stdlib documentation as the recommended hardener). The risk is benign — adds ~30 KB to the `/process_dmarc` zip. Pin to a specific version (`defusedxml==0.7.1` at PR time).
- **DMARC sender allowlist may drop legitimate reports** from senders we haven't observed yet. Mitigation: the skipped-message log line is rate-limited and includes the `From:` header so we can extend the allowlist as we see real traffic. Skips are silent, not bounces.
- **BCC-strip via two-message shape changes the SMTP envelope** for backup tooling that snapshots the Outbox. Today no such tooling exists; if it ever does, document that the Outbox-stored copy is not bit-identical to the wire copy.
- **Per-handler validators raise the latency floor** by a few hundred microseconds. Negligible against the existing IMAP round-trip cost.
- **DNS zone verification adds one Route 53 API call per cold start** per zone. Free at our scale (Route 53 read-only calls are pennies/month). The cache is keyed on `zone_id`, so warm invocations skip it.
- **Audit-log volume.** Admin mutations are rare (operator activity only). CloudWatch Logs cost is negligible.

## CI changes

- New per-function `requirements.txt` entry: `defusedxml==0.7.1` in `lambda/api/process_dmarc/requirements.txt`. Picked up by the existing `build-api.sh` flow automatically.
- New env var `DMARC_REPORT_SENDERS` wired through `terraform/infra/modules/app/dmarc.tf` and into the Lambda's environment block.
- New env var `MAX_DMARC_PAYLOAD_BYTES` (default 50 \* 1024 \* 1024) and `MAX_DMARC_MESSAGES_PER_RUN` (default 50) wired through the same path. Defaults baked into the code, env override available for tuning without a code change.
- New DynamoDB table `cabal-rate-limits` in `terraform/infra/modules/table/` with TTL attribute (`expires_at`, `Number` Unix seconds). On-demand billing. PITR enabled (matches the posture for other tables once [`resilience-continuity-hardening-plan.md`](./resilience-continuity-hardening-plan.md) lands).
- New GSI on `cabal-addresses` (`user-address-index`, partition `user`, sort `address`) added in `terraform/infra/modules/table/`. Backfill is automatic for on-demand tables.

## Acceptance

- Sending a malformed DMARC XML payload (XXE probe, billion-laughs, 100x-compression zip bomb) to the dmarc@ address results in: zero records written to `cabal-dmarc-reports`, one structured log line categorising the failure, and Lambda runtime under 5 seconds.
- A real DMARC aggregate report from a sender in the allowlist still parses end-to-end; the row count in `cabal-dmarc-reports` after the next scheduled run matches the report's record count.
- Sending an email with both To and Bcc recipients via `/send` results in: BCC addresses are present in the envelope `RCPT TO` list (verified via NLB access log entries from [`resilience-continuity-hardening-plan.md`](./resilience-continuity-hardening-plan.md) Phase 2), and the Sent-folder copy has no `Bcc:` header (verified by `imapclient.fetch(... ['BODY[HEADER]'])`).
- A `/move_messages` request with `destination` set to `..\r\nDESTRUCTIVE` returns 400 from the Lambda *without* opening an IMAP session.
- A `/new` request with `tld = "example.com"` (not in the configured `DOMAINS`) returns 400. A `/new` request with `tld` in `DOMAINS` but a zone ID that doesn't actually own the apex (synthesised by hand-editing the env var on dev) returns 500 with a `zone-mismatch` log line.
- An admin caller issuing 31 deletes in 60 seconds gets a 429 on the 31st, an audit log entry for each of the first 30, and a single rate-limit-tripped log entry.
- Every handler under `lambda/api/` returns 400 (not 500) when given a non-JSON body.

## Open questions

- **Should `defusedxml.ElementTree` replace stdlib ElementTree across all Lambdas, or only `/process_dmarc`?** Only `/process_dmarc` parses untrusted XML; the others (`fetch_bimi`, etc.) call into dnspython rather than parsing XML. Recommendation: scope to `/process_dmarc` until another untrusted-XML surface appears.
- **Audit log destination.** CloudWatch Logs (Insights query) is the cheapest default. If the audit trail needs to outlive the 14-day retention, route via a subscription filter to S3 (with object lock — see [`resilience-continuity-hardening-plan.md`](./resilience-continuity-hardening-plan.md)). Defer until we have a concrete retention requirement.
- **Per-caller rate limit vs per-IP rate limit.** Per-caller is what we want for admin mutations (the attacker has the credential, not the network). Per-IP would be a WAF concern, covered in the identity/IAM plan.
- **Should we adopt `email.policy.SMTPUTF8` or stick with `EmailMessage`'s default policy?** Today we accept Unicode in subjects via the default policy's RFC 2047 encoding. SMTPUTF8 is a separate axis; flagging for follow-up.

## Out of scope for 0.10.x

- IMAP search-expression parser. Document the surface; defer.
- Subject/body content scanning (anti-malware, anti-phishing on outbound). Separate posture decision.
- Per-recipient rate limits on `/send` (anti-spam for compromised user accounts). Captured as a follow-up: `MAX_RECIPIENTS_PER_HOUR_PER_USER` is an obvious next knob once we have audit-log data.
- Replacing the IMAP master-user model with per-user OAuth-style delegation. Architectural — not 0.10.x.

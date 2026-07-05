# Outbound DMARC Aggregate Reports (tentative)

**Status:** Tentative design, not on the roadmap. Written 2026-07-05.
Depends on
[`docs/0.10.x/inbound-auth-verification-plan.md`](../0.10.x/inbound-auth-verification-plan.md)
shipping first — without inbound verification there is nothing to report.

## Context

We participate in the DMARC reporting ecosystem in one direction only. As a
*sender*, we publish strict policies and ingest the aggregate reports other
receivers send us (`lambda/api/process_dmarc` → `cabal-dmarc-reports` →
admin Dmarc view). As a *receiver*, we send nothing: domains whose mail we
accept never learn how their messages authenticated at our MX.

Once the inbound verification plan lands, smtp-in evaluates SPF/DKIM/DMARC
on every inbound message. This plan closes the loop: accumulate those
per-message verdicts per sending domain, and once a day emit an RFC 7489
aggregate report to each domain's published `rua=` address, exactly as
Google and Microsoft do for us.

**Honest value assessment:** we are a small MX. Our reports will be tiny
and go mostly to large senders who will barely notice them. The reasons to
do it anyway: it is correct ecosystem citizenship; the reports become
genuinely useful to any smaller correspondent domain debugging its DMARC
rollout; and the marginal cost on top of the verification plan is one
DynamoDB table, one shipper daemon, and one Lambda. If that trade ever
stops looking worthwhile, this doc stays tentative.

## Goals

- Every domain that (a) sent us mail through smtp-in during a UTC day and
  (b) publishes a valid `rua=` destination receives one aggregate report
  for that day, spec-compliant enough that the big receivers' pipelines
  accept it (gzip XML, correct filename, correct subject, external
  destination verification honored).
- Report generation is idempotent per (domain, day) — a retried Lambda run
  never double-sends.
- The pipeline has a heartbeat and a runbook, mirroring the ingest side
  (`docs/operations/runbooks/heartbeat-dmarc-ingest.md`).

## Non-goals

- Forensic/failure reports (`ruf=`). Privacy-sensitive, rarely consumed,
  and a per-message real-time pipeline is a different shape of system.
- Honoring `ri=` intervals other than daily. RFC 7489 explicitly blesses
  a fixed daily cadence.
- Reporting on mail that did not transit smtp-in.
- Any change to inbound mail handling — this is a read-side consumer of
  the verification plan's output.

## Design

### Capture: OpenDMARC history file + per-task shipper

OpenDMARC (running in monitor mode per the verification plan) can write a
per-message **history file**: an append-only record of exactly the fields
an aggregate report row needs (source IP, header-from, envelope-from,
SPF/DKIM/DMARC results and alignment, the sender's published policy,
disposition). This is the purpose-built capture point — richer than
anything reconstructable from maillog — but it is a local file, and
smtp-in is a multi-task ECS service with stateless containers.

Resolution: a small **shipper daemon** in the smtp-in container
(supervisord program, same idiom as `docker/shared/reconfigure.sh`) that
every ~10 minutes rotates the history file, parses the completed slice,
and folds it into DynamoDB with `UpdateItem`/`ADD` counter increments.
Properties:

- **Multi-task safe.** Each task ships only its own slice; `ADD` merges
  concurrent writers without coordination.
- **Restart-tolerant.** A dying container loses at most the unshipped
  ~10-minute window. Aggregate reports are best-effort counts; the spec
  has no exactness requirement, and every large operator loses slices the
  same way.
- **No new movable parts on the mail path.** The milter writes locally;
  shipping is fully asynchronous.

Rejected alternatives: parsing CloudWatch maillog (opendmarc's syslog
lines don't carry full row fidelity — alignment detail and published
policy are missing) and mounting the history file on EFS (shared-write
append from multiple tasks to one file is exactly the failure mode the
stateless design avoids).

**IAM note:** the smtp-in task role today only *reads* config state
(`cabal-addresses` via `generate-config.sh`). Writing to the new stats
table is a new permission — a real IAM delta, so this routes through
stage, never direct-to-prod scaffolding.

### Table: `cabal-dmarc-outbound-stats`

Sibling of `cabal-dmarc-reports` in
[`terraform/infra/modules/table/main.tf`](../../terraform/infra/modules/table/main.tf):

- `pk` (S): `<policy-domain>#<YYYY-MM-DD>` (UTC day of receipt)
- `sk` (S): `<source-ip>#<disposition>#<dkim-aligned>#<spf-aligned>` — the
  RFC 7489 `<record>` grouping key
- `count` (N): incremented via `ADD`
- Published-policy attributes observed at evaluation time (`p`, `sp`,
  `adkim`, `aspf`, `pct`) and representative per-method auth detail
  (dkim domain/selector/result, spf domain/scope/result) — set once per
  row, `if_not_exists`
- `report_sent` (S): report-id, written by the generator for idempotency
- `expires_at` (N): TTL, ~14 days (the `cabal-rate-limits` pattern)

Volume is bounded by inbound mail volume × distinct (ip, verdict) tuples
per domain — for this MX, trivially within on-demand pricing noise.

### Generator: `lambda/api/generate_dmarc_reports`

EventBridge-scheduled daily (shortly after 00:00 UTC, generating for the
previous UTC day) — the `process_dmarc` orchestration pattern. Per policy
domain with rows for the day:

1. **Discover destinations.** Fresh DNS TXT lookup of
   `_dmarc.<policy-domain>`; parse `rua=` mailto URIs (cap at 2
   destinations, per spec allowance to limit). No record or no `rua=` →
   skip silently; that's the common case and not an error.
2. **External destination verification.** Where the `rua` address's
   domain differs from the policy domain, require the
   `<policy-domain>._report._dmarc.<destination-domain>` TXT
   authorization record (RFC 7489 §7.1). Skipping this check produces
   reports that compliant receivers discard — it is not optional.
   Honor a `!10m`-style size suffix if present (our reports are far
   smaller in practice).
3. **Build.** RFC 7489 Appendix C XML: `report_metadata` (org = control
   domain, contact = `dmarc-reports@mail-admin.<first-mail-domain>`,
   report-id, epoch date range), `policy_published` from the stored
   attributes, one `<record>` per sk row. Gzip. Filename
   `<control-domain>!<policy-domain>!<begin>!<end>.xml.gz`; subject
   `Report Domain: <policy-domain> Submitter: <control-domain>
   Report-ID: <report-id>`.
4. **Send.** SMTP submission through smtp-out as the existing `dmarc`
   system account, from `dmarc-reports@mail-admin.<first-mail-domain>`
   (the address already provisioned by
   [`terraform/infra/modules/app/dmarc_user.tf`](../../terraform/infra/modules/app/dmarc_user.tf)
   with full MX/SPF/DKIM/DMARC — our reports authenticate cleanly at the
   receiving end). How the Lambda authenticates to Dovecot submission as
   a system account is the main implementation detail to pin down:
   master-user credentials from SSM (the IMAP-side pattern) if Dovecot's
   submission service honors them, else a dedicated SSM-stored password
   for the `dmarc` account.
5. **Mark sent.** Write `report_sent = <report-id>` on the day's rows
   (conditional on absence) before SMTP; a retried run skips marked
   domains. Crash-between-mark-and-send loses one domain-day rather than
   double-sending — the right side to err on.

### Monitoring

Healthchecks heartbeat ping per run (the `process_dmarc` pattern), a
`heartbeat-dmarc-outbound.md` runbook, and structured per-domain
sent/skipped/failed counts in the Lambda log
(`/cabal/lambda/generate_dmarc_reports`).

## Phases

1. **Capture + table.** History file config on smtp-in, shipper daemon,
   `cabal-dmarc-outbound-stats` table, task-role write grant. Verifiable
   on stage by inspecting table rows after sending test mail — no reports
   leave the system yet.
2. **Generator + delivery.** The Lambda, its Terraform (role, schedule,
   SSM access), first live sends on stage. Stage receives real inbound
   mail from Google et al., so destinations are real: keep stage's
   schedule disabled by default and fire manual test runs against a
   single allowlisted domain first.
3. **Ops.** Heartbeat, runbook, and (optional, symmetric with ingest) a
   "reports we sent" tab in the admin Dmarc view reading the marked rows.

## Open questions

- OpenDMARC history-file record format stability across versions — parse
  defensively; the shipper should skip-and-log unknown record types.
- Whether Dovecot submission accepts master-user auth (determines step 4
  above).
- Whether to include our own domains' inbound mail (mail from one
  cabalmail user to another arrives via smtp-out→imap, not smtp-in, so in
  practice this is moot unless routing changes).
- Whether the admin view in phase 3 is worth building before anyone asks
  for it.

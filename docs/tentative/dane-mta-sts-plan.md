# SMTP transport security: DANE over MTA-STS (tentative)

**Status:** Tentative design, deliberately deprioritized. Written
2026-08-01. Research and recommendations recorded so the reasoning
survives; nothing here is on the roadmap. Prerequisite state at time of
writing: DNSSEC live in stage (zone signing), not yet in prod.

## Context and threat model

Both MTA-STS (RFC 8461) and DANE for SMTP (RFC 7672) exist to fix the
same structural weakness: SMTP TLS is opportunistic. A sender that
reaches our smtp-in and sees no STARTTLS offer cannot distinguish "this
receiver never had TLS" from "an on-path attacker stripped the
capability," so it delivers in cleartext by design. Likewise, with no
policy to check against, the sender accepts any certificate. The point
of these protocols is *not* to change lazy-sender behavior — it is to
hand diligent senders a commitment they can hold us to ("I always do
TLS; the real MX presents this identity"), converting silent
interception into a refused connection.

The realistic adversary is therefore an *active, targeted* one:
STARTTLS stripping by an on-path network, or a DNS/BGP hijack that
redirects mail to an attacker's MX. Passive bulk surveillance is
already mostly defeated by the ~95%+ opportunistic-TLS rate. For this
system the single highest-value interception target is inbound
account-recovery mail — our per-vendor addresses are the recovery root
for every account the user signs up for. Conveniently, the senders of
exactly that mail class (Google, Microsoft, and services fronted by
them) overlap heavily with the small population that enforces these
policies outbound. The protocols do the most good on precisely the
mail where interception hurts most.

**Honest value assessment:** small-probability, high-impact. Worth
having only where the marginal cost is near zero. That criterion is
what decides between the two protocols below.

## Why MTA-STS does not fit this architecture

MTA-STS policy discovery is per *recipient domain*, with no wildcard
or parent-domain inheritance: a sender delivering to
`user@j56lu9xq.cabalmail.com` looks up
`_mta-sts.j56lu9xq.cabalmail.com` and fetches
`https://mta-sts.j56lu9xq.cabalmail.com/.well-known/mta-sts.txt`. A
policy at the apex covers nothing. Because the `new` Lambda mints a
fresh subdomain MX per address (`lambda/api/new/function.py`), full
coverage means MTA-STS machinery per address:

- The `_mta-sts.<sub>` TXT record is easy — the Lambda could add it
  alongside the MX it already creates.
- The HTTPS policy host is not. `mta-sts.<sub>.cabalmail.com` needs a
  publicly trusted certificate for that exact name, and a wildcard
  `*.cabalmail.com` does not cover a second label. Full coverage
  turns address creation into a cert-issuance pipeline: per-address
  issuance, Let's Encrypt rate limits, renewal tracking, and
  CloudFront/SNI routing all scaling O(addresses).

Secondary cons: testing mode without TLSRPT ingestion is a no-op (its
only output is reports); sender enforcement is roughly Gmail +
Outlook.com and little else; and `max_age` policy caching (typically
weeks) makes enforce-mode mistakes sticky at senders with no way to
flush them remotely.

**Verdict: rejected.** The per-recipient-domain design is structurally
wrong for per-address subdomain addressing.

## Why DANE fits

DANE binds trust to the *MX hostname*, not the recipient domain. Every
address subdomain, present and future, MXes to the single
`smtp-in.<control_domain>`, whose certificate is already the Let's
Encrypt `*.<control_domain>` wildcard (certbot-renewal Lambda). One
TLSA record at `_25._tcp.smtp-in.<control_domain>` therefore covers
every address ever created, with zero per-address work — the
per-address MX records are covered by Route 53 zone signing
automatically. Cost is O(1) forever:

1. DNSSEC on the control-domain zone (done in stage; prod pending
   CI-policy grants — see the identity/DNSSEC work).
2. One TLSA record, `3 1 1` (DANE-EE, SPKI SHA-256) against the
   smtp-in cert's public key.
3. Rollover logic in the certbot-renewal Lambda: publish the *next*
   key's digest alongside the current one before any rotation, so a
   renewal never strands validating senders.

Sender-side coverage cuts differently from MTA-STS: Outlook.com/M365
and most of the self-hosted Postfix/Exim world validate DANE
outbound; Gmail does not. Between the two protocols the enforcing
populations roughly complement each other, but only DANE is
deployable here at fixed cost.

## No advisory mode — and why DANE needs one less

DANE has no equivalent of MTA-STS `mode: testing`, structurally: the
policy *is* the TLSA record's existence in signed DNS. There is no
document to carry a mode flag; enforcement is decided sender-side
(e.g. Postfix `dane` vs `dane-only`). Approximations of a test mode:

- **TLSRPT (RFC 8460) canary.** TLSRPT is not MTA-STS-specific; report
  result types include `tlsa-invalid` and `dnssec-invalid`. Publish
  `_smtp._tls` TXT with `rua=` pointing at a
  `mail-admin.<first-mail-domain>` address, optionally before the TLSA
  exists, to baseline. Caveats: the record hangs off the recipient
  domain (same per-subdomain scaling wall — canary on `mail-admin`
  only), and the population that both validates DANE and sends TLSRPT
  is essentially Microsoft.
- **Stage is the real test mode.** Enforcement follows the record, so
  a TLSA on stage's control domain is a full-fidelity dress rehearsal.
  Validate with `posttls-finger`, danecheck, or dane.sys4.de, and send
  live mail from a DANE-enforcing sender (an outlook.com account, or
  stock Postfix with `smtp_tls_security_level = dane`).
- **Mistakes self-heal on DNS timescales.** A bad MTA-STS policy is
  cached at senders for `max_age` (weeks). A bad TLSA record is cached
  for its DNS TTL: publish at TTL 300 during rollout and a fix
  propagates in five minutes. Validating senders also treat mismatch
  as tempfail — mail queues and retries for days — so a mistake
  caught within a day delays mail rather than losing it.

## Failure visibility (the sharpest edge)

If a DANE-validating sender fails to verify us, everything observable
happens on *their* side: they abort after the handshake, tempfail,
retry for days, and eventually bounce — to the message's author, not
to us. Our maillog shows only a TLS session dropped without MAIL,
indistinguishable from scanner noise. A botched TLSA record means mail
from Outlook and the Postfix world quietly stops arriving, and the
first notice is a human saying their mail bounced. Countermeasures, in
increasing order of value:

1. **TLSRPT canary** (above): ~24h-latency digests, Microsoft-only in
   practice. Nice to have, not the alarm.
2. **Synthetic probe.** The failure mode is deterministic — published
   TLSA digest vs the cert smtp-in presents — so no real traffic is
   needed to detect it. A small scheduled Lambda (monitoring stack is
   off everywhere) resolving the TLSA RRset and checking the port-25
   cert catches breakage in minutes; the senders' multi-day tempfail
   window means even hourly checks turn "lost" into "delayed."
3. **Fail-closed rotation — the load-bearing control.** The realistic
   breakage is the certbot-renewal Lambda rotating to a key whose
   digest is not yet published. Guard inside the pipeline: after
   renewal, verify the new cert's SPKI digest is already present in
   the live TLSA RRset *before* writing the cert to SSM and rolling
   the ECS services. If absent, keep serving the old cert (renewal
   fires at ~30 days remaining, so there is a month of runway) and
   alert. This converts "silent inbound outage" into "renewal
   postponed, loud complaint." With this in place, the monitoring
   above is belt-and-suspenders.

## Sending side: we do not validate DANE

Three independent layers each say no today:

1. `docker/templates/out-sendmail.mc` sets no DANE option — outbound
   is plain opportunistic STARTTLS (encrypt if offered, verify
   nothing, silent cleartext fallback).
2. The pinned `amazonlinux:2023` base ships sendmail 8.17.1. DANE in
   the 8.16/8.17 line was an experimental compile-time flag distro
   builds don't enable; it became a real configurable feature
   (`DANE=basic`/`always`) in sendmail 8.18.1 (2024-01). No knob
   exists in our binary.
3. Sender-side DANE needs a DNSSEC-validating resolver whose AD bit
   the MTA trusts. The containers use the VPC Route 53 Resolver,
   which does not validate unless the per-VPC resolver setting is
   enabled (distinct from zone signing, which is the receiving side).

Closing the gap would require sendmail ≥ 8.18 (unlikely from AL2023;
otherwise compile in the image), `DANE=basic` in the `.mc`, and a
trusted validating resolver (VPC resolver validation, or better, a
local unbound in the container so AD is not trusted across a network
hop). Payoff: protects mail we send to TLSA-publishing domains —
Microsoft MXs and the Postfix world, no Gmail. Severable from the
inbound decision; low priority.

## Recommendation summary

- **Skip MTA-STS entirely.** Architecturally wrong shape; revisit only
  if the per-address-subdomain addressing model ever changes.
- **DANE inbound is the eventual play**, gated on DNSSEC reaching
  prod. Cheap insurance on the one flow (account recovery) where
  interception would genuinely hurt. Rollout: TLSRPT canary on
  `mail-admin` → stage TLSA at TTL 300 → external validators + live
  Outlook/Postfix sends → prod at low TTL → raise TTL only after the
  certbot Lambda's publish-current-and-next rollover has survived one
  real renewal cycle.
- **Ship the fail-closed rotation check with the TLSA record, not
  after it.** It is the difference between the failure mode being an
  outage and being an inconvenience.
- **Sender-side DANE: file under symmetry.** Revisit if AL2023 ever
  ships sendmail ≥ 8.18 or if smtp-out is rebuilt for other reasons.

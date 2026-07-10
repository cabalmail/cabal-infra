# CAA records

[Certification Authority Authorization](https://www.rfc-editor.org/rfc/rfc8659) (CAA)
records tell certificate authorities which of them, if any, may issue a
certificate for a domain. A CA is required to check CAA before issuing, so a
published CAA record is a cheap, standards-backed lock against mis-issuance: no
CA outside the authorized set can mint a certificate for your names, even if it
is tricked into trying.

Cabalmail publishes CAA in Terraform (`terraform/infra/modules/caa`), so the
policy is version-controlled and applied alongside the certificates it governs.
The records are read at plan time from the same zone IDs the certificate modules
use, so they cannot drift away from where certificates are actually issued.

## What is authorized

Every TLS certificate Cabalmail issues is a wildcard for the control domain,
`*.<control_domain>`, from one of two CAs:

- **ACM** (`modules/cert`) - the certificate on the load balancer and
  CloudFront, DNS-validated in the control-domain zone.
- **Let's Encrypt** (`modules/certbot_renewal`) - the certificate the mail
  tiers present for IMAPS and SMTP submission, renewed by the certbot Lambda
  over DNS-01.

Because both are wildcards, each authorized CA is granted `issue` (exact names)
and `issuewild` (wildcards).

| Zone | Authorized CAs | Why |
|------|----------------|-----|
| Control domain | ACM + Let's Encrypt | Both certificates live here. |
| Each mail domain | ACM only | See below. |

**ACM is authorized by four identifiers** - `amazon.com`, `amazontrust.com`,
`awstrust.com`, and `amazonaws.com`. ACM's issuing intermediates vary by region
and by the AWS service consuming the certificate, so all four are authorized to
avoid a surprise validation failure. This follows
[AWS's CAA guidance](https://docs.aws.amazon.com/acm/latest/userguide/setup-caa.html).

**Let's Encrypt is authorized on the control domain only.** It is not an
oversight that the mail domains omit `letsencrypt.org`: certbot is hardwired to
`CONTROL_DOMAIN`, and the mail services present control-domain hostnames
(`imap.<control_domain>`, `smtp-out.<control_domain>`), so a mail apex never
terminates a Let's Encrypt certificate. Mail domains keep ACM authorized because
ACM is the AWS-native path should a mail domain ever be fronted by an AWS
service.

A single record at the control-domain apex governs every infrastructure
subdomain: a CA validating `*.<control_domain>` walks up the DNS tree, finds the
apex record, and stops. Mail domains are addressing-only (MX/SPF/DKIM/DMARC) and
carry no certificates today; their CAA is defense-in-depth so that no CA may
issue for them without a deliberate policy change here.

## Violation reporting (iodef)

Each record carries an `iodef` property pointing at
`caa-reports@mail-admin.<first mail domain>`, a system-managed address
provisioned alongside `dmarc-reports` and delivered to the same system
mailbox. A conformant CA that receives a request violating the policy can
report it there.

These reports follow the DMARC-report pipeline: the scheduled `process_dmarc`
Lambda recognizes messages addressed to `caa-reports`, archives the raw
message to S3 (`caa/` prefix in the cache bucket), records it in the
`cabal-caa-reports` DynamoDB table, and the admin site's **CAA** view (admin
group only) lists them with the raw message viewable and downloadable.

Unlike DMARC aggregate reports, which arrive daily from every major receiving
provider, CAA violation reports are expected to *never* arrive: a CA sends one
only when it refuses a certificate request that violates this policy, and
`iodef` support is optional and patchy among CAs (Let's Encrypt does not send
them). An empty CAA view is the healthy state. Any report that does appear
means someone asked a CA to issue for one of your domains and was refused -
investigate it.

Two operational notes:

- Messages to `caa-reports` bypass the DMARC sender allowlist
  (`DMARC_REPORT_SENDERS`): reports come from whichever CA refused the
  request, and the set of CA sender domains is not knowable in advance.
- The address row is written to DynamoDB by Terraform, so the mail tiers pick
  it up at the next periodic sendmail map regeneration rather than instantly
  (the SNS-triggered reconfigure fires only for addresses created through the
  app).
- To also receive these reports in a personal mailbox, assign an additional
  user to the address via the `assign_address` admin API (the owning `dmarc`
  user is hidden from the admin UI, but the API only validates the user being
  added). Terraform ignores drift on this row, so the assignment survives
  later applies.

## Authorizing a new CA

To let another CA issue for a domain - for example, adding DigiCert or Entrust
for a [BIMI](https://bimigroup.org/) Verified Mark Certificate on a mail domain -
edit `terraform/infra/modules/caa/main.tf`:

- Add the CA's identifier to `local.acm_issuers` (badly named for a
  mail-domain-wide addition; rename to taste) or build the record list it
  belongs in.
- For a control-domain-only CA, add it to `local.control_issuers`.

Apply through the normal infra pipeline. Removing a CA is the same edit in
reverse; existing certificates keep working, but that CA can no longer renew or
re-issue.

## Verifying

A CAA record that *looks* right in Route 53 proves nothing by itself: CAA has
no effect on existing certificates or mail flow, and only gates *new*
issuance. A wrong record therefore breaks nothing today and then quietly
blocks the next renewal. Verify both directions - that the policy blocks what
it should and still allows what it must - by forcing real issuance attempts
rather than waiting for the next renewal to find out.

Requesting a certificate your own CAA policy forbids is responsible and
routine: CAA denial is designed-for CA behavior, the refusal is logged like
any failed validation, and nothing reaches Certificate Transparency (CT logs
record only issued certificates). Use staging endpoints where offered and
keep it to a handful of manual attempts.

### 1. Record visibility

After an apply, confirm what public resolvers see (the CA queries your
authoritative servers, not your local cache):

```
dig +short CAA <control_domain> @1.1.1.1
dig +short CAA <mail_domain> @1.1.1.1
```

You should see the `issue`/`issuewild` lines for the authorized CAs and the
`iodef` line. Allow for the record TTL (one hour by default) before expecting
a change to be visible everywhere.

Where the zone is DNSSEC-signed, also confirm the CAA RRset validates - a CA
whose CAA lookup gets SERVFAIL must treat it as a hard failure, so a broken
signature blocks issuance even when the record content is correct:

```
dig +dnssec CAA <mail_domain> @1.1.1.1
```

Expect the records plus an `RRSIG CAA`, and the `ad` flag in the header.

### 2. Negative test: an unauthorized CA is refused

Let's Encrypt is not authorized on the mail domains, and its staging endpoint
performs real CAA checks without touching production rate limits - so it makes
a perfect refusal probe. From CloudShell in the account that owns the zone
(certbot's Route 53 plugin picks up the session credentials automatically):

```
pip3 install --user certbot certbot-dns-route53

~/.local/bin/certbot certonly --staging --dns-route53 \
  --domains caa-test.<mail_domain> \
  --config-dir /tmp/cb --work-dir /tmp/cb --logs-dir /tmp/cb \
  --email <you> --agree-tos --non-interactive
```

Expected: failure citing `CAA record for caa-test.<mail_domain> prevents
issuance`. A DNS or permission error from the plugin *before* any CAA mention
means the Route 53 TXT write failed (wrong account) - that is not a CAA
result. To probe the control domain's lockdown with a CA outside its
authorized set, ZeroSSL or Buypass (both free ACME CAs) behave the same way.

### 3. Positive test: the authorized CAs can still issue

This is the higher-stakes direction - it is the one whose failure mode is a
silently broken renewal weeks later.

- **Let's Encrypt on the control domain**: rerun the certbot command above
  with `--domains caa-test.<control_domain>`. Expected: a staging certificate
  is issued. The fuller version is invoking the `cabal-certbot-renewal`
  Lambda, which exercises the production renewal path itself at the cost of
  rolling the mail tiers.
- **ACM on the control domain**: request a throwaway DNS-validated
  certificate for `caa-test.<control_domain>`, confirm it reaches ISSUED,
  then delete it. This proves whichever Amazon issuing intermediate serves
  your region is within the authorized set.

For a zero-issuance preflight, [Let's Debug](https://letsdebug.net) runs
Let's Encrypt-style CAA and DNSSEC checks against a domain without requesting
anything.

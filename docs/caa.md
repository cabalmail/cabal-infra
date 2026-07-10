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

Each record carries an `iodef` property pointing at the Let's Encrypt contact
email (`TF_VAR_EMAIL`). A conformant CA that receives a request violating the
policy can report it to that address. Treat any such report as a signal worth
investigating.

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

CAA records are signed automatically when the zone has DNSSEC enabled; no extra
steps. After an apply, confirm what resolvers see:

```
dig +short CAA <control_domain>
dig +short CAA <mail_domain>
```

You should see the `issue`/`issuewild` lines for the authorized CAs and the
`iodef` line. Allow for the record TTL (one hour by default) before expecting a
change to be visible everywhere.

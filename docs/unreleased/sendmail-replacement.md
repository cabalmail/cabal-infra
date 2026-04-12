# Replacing Sendmail on the SMTP-OUT Tier

## Background

With the containerization migration (see `docs/0.4.0/containerization-plan.md`),
Dovecot now handles user-facing SMTP submission on the smtp-out tier (ports
587/465), authenticating users via PAM against Cognito. Dovecot then relays to
sendmail on localhost:25 for outbound delivery. This architecture reduces
sendmail's role significantly, making it a good candidate for replacement.

## What Sendmail Currently Does on SMTP-OUT

Sendmail is **not** a dumb relay. It performs:

1. **Masquerading** — Rewrites From: addresses using a dynamically-generated
   `masq-domains` file (all hosted domains from DynamoDB).
2. **Mailertable routing** — If the recipient is on a hosted domain, routes the
   message back to the IMAP container (`smtp:[imap.internal]`) rather than
   sending it externally.
3. **DKIM signing** — Passes outbound mail through the OpenDKIM milter.
4. **Access control / rate limiting** — 500 messages/day/sender, 100
   recipients/transaction.

The greet pause that was previously configured has been removed, as the only
client connecting to sendmail on smtp-out is Dovecot on localhost.

## Recommended Replacement: Postfix

Postfix is the most straightforward replacement. The configuration mapping is
nearly 1:1:

| Sendmail feature | Postfix equivalent |
|---|---|
| `masq-domains` | `masquerade_domains` |
| `mailertable` | `transport_maps` |
| `access` db | `smtpd_client_restrictions` / `check_client_access` |
| `INPUT_MAIL_FILTER(opendkim)` | `smtpd_milters` / `non_smtpd_milters` |
| `makemap hash` | `postmap hash` |

### Migration effort

- Rewrite `out-sendmail.mc` as Postfix `main.cf` / `master.cf`.
- Update `generate-config.sh` and `reconfigure.sh` to use `postmap` instead of
  `makemap` and to signal Postfix (`postfix reload`) instead of sendmail.
- Update the Dockerfile to install `postfix` and `postfix-pcre` instead of
  `sendmail` and `sendmail-milter`.
- The DynamoDB query logic in the config generation scripts stays the same.

### Why not OpenSMTPD?

OpenSMTPD has a simpler configuration language but weaker milter support. Since
we rely on the OpenDKIM milter for DKIM signing, Postfix's mature milter
integration is the safer choice.

## What About SMTP-IN?

Sendmail on smtp-in has a more complex role (inbound delivery, alias resolution,
virtual user handling) and benefits from the greet pause for anti-spam. Replacing
sendmail on smtp-in is a larger effort and should be evaluated separately.

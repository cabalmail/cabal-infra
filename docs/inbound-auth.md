# Inbound sender authentication (SPF / DKIM / DMARC verdicts)

The smtp-in tier verifies sender authentication on every inbound message and stamps the verdicts into an `Authentication-Results` header. The clients display them; nothing is ever rejected because of them.

## The milter chain

Two milters run in the smtp-in container (configs in `docker/smtp-in/configs/`):

- **OpenDKIM** in verify-only mode (`Mode v`): checks signatures against the sender's published DNS keys and stamps the `dkim=` verdict. No signing — signing lives on smtp-out.
- **OpenDMARC** 1.4.2, built from source in the image (AL2023 does not package it), `--with-spf`: performs its own SPF check (`SPFSelfValidate`), reads OpenDKIM's verdict, evaluates the sender's DMARC policy, and appends `spf=` and `dmarc=`.

Both are observe-only: `RejectFailures false`, so every disposition is accept. The verdict is surfaced to the user, never enforced by the relay.

## The trust rule

Verdicts are stamped under the environment's control domain as the authserv-id. Two defenses keep them trustworthy:

- OpenDKIM's `RemoveARFrom` strips any inbound `Authentication-Results` header that *claims* our authserv-id before fresh ones are stamped, so a sender cannot pre-load a forged `dmarc=pass`.
- `parse_auth_results` in `lambda/api/_shared/helper.py` parses only headers whose authserv-id is exactly the control domain; everything else is ignored.

## What clients see

Envelope and message payloads carry an `auth_results` field with per-method verdicts (`pass`/`fail`/`none`/…). Both the web and Apple readers render a verdict line, with a "not verified" fallback for mail that predates the feature or arrived without a header (e.g. locally submitted). Design history: [0.10.x/inbound-auth-verification-plan.md](./0.10.x/inbound-auth-verification-plan.md).

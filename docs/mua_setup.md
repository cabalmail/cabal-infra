# Configuring Mail User Agents

## Sending mail

Outbound submission is available only through the Cabalmail clients (the
native Apple apps and the admin web app), which send via the Lambda API.
There is no public SMTP submission endpoint, so generic mail clients
cannot be configured for outgoing mail; the `_submission._tcp` SRV
record advertises this per RFC 6186, which stops well-behaved clients
from probing.

## Incoming Settings

Mailbox access over IMAP remains available to standard clients
(substituting your control domain for `example.net`):

| Setting  | Value                    |
| -------- | ------------------------ |
| Type     | IMAP                     |
| Port     | 993                      |
| SSL      | Yes                      |
| Login    | Plain                    |
| Server   | imap.example.net         |
| Username | As entered during signup |
| Password | As entered during signup |

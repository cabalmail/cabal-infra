# Configuring Mail User Agents

## Sending mail

Outbound submission is available only through the Cabalmail clients (the
native Apple apps and the admin web app), which send via the Lambda API.
There is no public SMTP submission endpoint, so generic mail clients
cannot be configured for outgoing mail; the `_submission._tcp` SRV
record advertises this per RFC 6186, which stops well-behaved clients
from probing.

## Reading mail

Mailbox access is available only through the Cabalmail clients (the
native Apple apps and the admin web app), which talk to the Lambda API.
There is no public IMAP endpoint, so generic mail clients cannot be
configured for incoming mail; the `_imaps._tcp` / `_imap._tcp` SRV
records advertise this per RFC 6186, which stops well-behaved clients
from probing.

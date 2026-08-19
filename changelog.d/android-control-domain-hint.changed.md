- Android: **Sign-in says what the control domain looks like.** The
  sign-in form now carries always-visible supporting text under "Control
  domain" naming the expected shape (`admin.example.com` — the host that
  serves the admin web app), and a domain that does not resolve is reported
  as "No such host" with that shape, instead of the generic
  check-your-connection line that also covers being offline. A tester
  typing a mail domain instead of the control domain had no way to tell
  which of the two was wrong.

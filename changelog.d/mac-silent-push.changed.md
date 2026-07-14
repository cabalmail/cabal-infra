- Apple: **Mac notifications are enriched whenever the app is running.**
  The server sends Macs a silent wake instead of a visible alert; the
  running app (focused or not) fetches the envelope and posts the
  sender/subject/snippet notification itself — no banner while the app is
  frontmost (it already shows the mail), and a generic "New mail" if the
  fetch fails. macOS kills notification service extensions before they run
  (a long-standing platform defect), so extension-side enrichment — the
  iOS approach — cannot work there; the extension stays shipped so a
  future macOS fix restores it, including for the one case this design
  cannot cover: a quit Mac app receives no notification (a paired iPhone
  shows the fully enriched banner regardless).

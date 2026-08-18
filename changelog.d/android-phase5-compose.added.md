- Android: **Compose with on-the-fly From and synced drafts.** The client
  can now write mail (Phase 5). The compose screen leads with a From picker
  that has no preselection - Send stays disabled until an owned address is
  chosen - with favorites first and "Create new address..." as its last item
  (a bottom sheet with local part, subdomain, permitted-domain picker,
  comment, and a Random fill), so minting a fresh relationship-scoped
  address is one tap away from every message. Recipients are chips with a
  learned autocomplete; the body is Markdown-canonical (a formatting
  toolbar over the Markdown buffer, rendered to the HTML part on the wire)
  so drafts round-trip losslessly with the Apple and web clients; photos
  and documents attach through the system pickers and stage to S3 via
  `/upload_url`. Reply / reply-all / forward open from a new bottom bar in
  the reader - From defaults to the owned address the original was sent
  to, subjects prefix idempotently, replies thread through the fetched
  body's headers overlaid on the envelope, and forward deliberately starts
  a new thread; a sent reply marks the original answered. Drafts follow the
  Apple sync model: a 5-second local buffer that survives a kill (offered
  at the next launch), a 60-second `/save_draft` sync that replaces the
  prior server copy, close-without-send saves to the server (or asks for a
  From, or drops an empty draft), Discard removes both copies, and messages
  in the Drafts folder offer Edit Draft with Bcc and threading recovered
  from the raw headers. Sending mints a session-stable Message-ID so a
  retry can never double-deliver, and hands the superseded draft to
  `/send` for cleanup. Cabalmail also registers as a share target: text,
  images, and files shared from other apps open a pre-filled compose.

- **Sent copies keep the Bcc header.** `/send` used to strip `Bcc` from the
  copy it stages for the Sent folder, permanently destroying the sender's
  only record of who they blind-copied. The stripping protected nothing:
  only the mailbox owner can read Sent, and blind recipients were never at
  risk on the wire (smtplib strips `Bcc` from the transmitted message, and
  delivery uses an explicit recipient list). Sent copies now retain `Bcc`,
  matching drafts and mainstream mail clients. Messages sent before this
  change are unaffected - their Bcc information was never stored and cannot
  be recovered.

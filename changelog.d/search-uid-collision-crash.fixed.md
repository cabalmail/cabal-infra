- Apple: **All-mail search crash when two results share a UID.** IMAP UIDs are
  unique only within a folder, so a cross-folder search routinely returns the same
  UID from two mailboxes; building the per-row source-folder map assumed otherwise
  and trapped, killing the app the instant results arrived. Each row now resolves
  to its own mailbox, so dispose, flag, move and open all target the right folder.

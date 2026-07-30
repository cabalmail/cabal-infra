- Apple: **Unresolvable skeleton row left behind by a locally-removed
  message.** Archiving, moving, permanently deleting or sending a draft pruned
  the row but left the folder's message total at its last server-reported
  value, so the vacated slot went on rendering a loading placeholder that could
  never resolve — and the `All` filter pill went on counting it — until the next
  folder-status poll corrected the count, up to a couple of minutes in an
  unsubscribed folder such as Drafts. Every optimistic removal now takes the
  slot off the total with the row, and hands it back if the server write fails.

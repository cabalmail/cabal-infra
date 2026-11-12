- **Five Apple-client comments now name identifiers that exist.** The Message
  menu's availability tests cited `shortcutTargetUIDs` at two sites, renamed to
  `shortcutTargetRefs` when the selection moved to `MessageRef`; the
  content-column policy tests cited `MailRootView.contentColumn`, deleted when
  the layout shells replaced that view, instead of `MailContentColumn`; the
  search filters mirrored a React `this_folder_only` key the webmail has never
  had, rather than its `thisFolderOnly` state; and the swipe-action row cited a
  planning-note slug for the virtualized list. Comments only, no code change.

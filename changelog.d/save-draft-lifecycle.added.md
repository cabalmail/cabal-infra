- New `/save_draft` Lambda gives drafts a server-side lifecycle: save
  returns the new copy's UIDPLUS `(uid, uidvalidity)`, save can atomically
  replace a prior copy (append-first, UIDVALIDITY-guarded, keeps both on a
  guard miss), and `op: discard` removes one — all scoped to the Drafts
  folder, mirroring the trash-scoping of the purge endpoints. `/send`
  accepts `discard_draft_uid` so send-from-draft cleans up the server copy
  after delivery; its `draft: true` branch is unchanged for React.

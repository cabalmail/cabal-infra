- Apple: **Multi-select on iPad and Vision Pro.** The message list's Select
  button did nothing on wide layouts, leaving bulk Archive / Move / Mark
  read-unread / Flag unreachable there — it drove a view-local `EditMode`
  that the virtualized list has no way to render. Every touch layout now
  shares the checkbox selection mode iPhone already used.

- Apple: **Confirmation dialogs offer a labelled way out again.** On iPhone
  and visionOS, "Revoke <address>?", "Suspend <address>?", "Delete Forever?",
  "Empty Trash?", the folder-delete prompt and the large-selection guard each
  rendered as a popover showing only their destructive button — SwiftUI drops
  a cancel-role button in popover presentation, so the sole labelled control
  was the irreversible one. All nine dialogs now take the back-out role from
  one shared rule, which macOS still resolves to a proper cancel for Escape.

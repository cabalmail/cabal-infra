- Apple: **Back-out button on the feed and flag confirmations.** Six
  confirmation dialogs — Delete Folder, Unsubscribe (from the feed sidebar
  and from the subscription settings sheet), both Mark All as Read dialogs,
  and Delete Flag in Settings — declared only their action button, so on
  iPhone and visionOS, where SwiftUI drops a cancel-role button, the only
  labelled control on screen was the action itself, destructive in four of
  the six. Each now offers the same back-out its fourteen siblings do, and a
  source-level invariant holds every `confirmationDialog` in the app targets
  to declaring one.

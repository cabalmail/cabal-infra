- Apple: **First visit to a folder no longer shows a red network("cancelled")
  error.** The message list's initial fetch ran inside a SwiftUI task that
  can be cancelled mid-push transition, painting the error over an empty
  list with nothing left to reload it; the first load now runs on a
  model-owned task that survives the transition. The HTTP transport also
  retries a spurious URLSession cancellation once, restoring the recovery
  the body fetch lost when transport-level error normalization landed.

- Apple: **Compose windows stop accumulating.** On macOS, iPadOS, and
  visionOS the compose scene group was keyed by the seed draft, and every
  compose session mints a new one, so SwiftUI retained a whole composer —
  view model, rich-text editor, and its web view — per session for the life
  of the app. Compose windows now take a recycled slot instead, which keeps
  a reply and a forward open side by side while bounding what is retained
  by how many composers are open at once. Measured on macOS: the per-session
  cost drops from ~8 MB to under 1 MB, flat across ten sessions.

- Apple: **"After delay (2s)" mark-as-read now actually fires on
  iPhone.** The 2-second delayed `\Seen` STORE was silently cancelled
  every time by a phantom `.onDisappear` — the same iPhone-only SwiftUI
  double-fire that #403 exempted body-fetch from — so a message opened
  under the "After delay (2s)" setting stayed unread no matter how long
  the user read it. `MessageDetailViewModel.onDisappear()` no longer
  cancels the pending task; the manual toggle and dispose paths still
  supersede it. `.onOpen` was unaffected.

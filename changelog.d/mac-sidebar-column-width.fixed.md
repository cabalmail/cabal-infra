- Apple: **macOS folder sidebar opens wide enough to read its folder names.**
  The sidebar took SwiftUI's default column width, which left `INBOX` and
  `Archive` rendering as `I…` and `Arc…` on every launch once the disclosure
  indent, unread badge and row menu had taken their share. It now opens at a
  width sized for a folder name, still resizes by the native divider, and
  remembers the width the user drags it to.

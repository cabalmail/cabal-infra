- Apple: **Readable folder names in the sidebar.** Colouring names by unread
  state had made the selected folder white on the light selection fill —
  1.52:1 on iPadOS, and invisible outright in the second row "All folders"
  draws for the folder already selected — while a caught-up folder's name
  dimmed to 4.00:1 there and 2.90–3.31:1 on macOS 27, all under the 4.5:1
  WCAG AA floor. The selected row now keeps whatever foreground its
  selection fill calls for instead of pinning one, and caught-up names dim
  by a fixed fraction of the label colour rather than by `.secondary`, whose
  alpha the OS picks without regard to contrast. The unread signal is
  unchanged; every state measured now clears AA on iPadOS and macOS.

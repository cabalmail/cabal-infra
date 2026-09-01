- **System light and dark mode in the browser extensions.** Both surfaces —
  the toolbar popup and the in-page overlay (suggest popover, adopt banner,
  submit-guard modal, ambiguous badge) — now follow the operating system's
  appearance setting instead of always rendering light. Colours come from a
  shared token file that the popup links and the overlay injects into its
  shadow root, and `color-scheme` is set so the native text inputs, the
  apex-domain picker, and the popup's buttons adopt the dark palette too.
  The overlay deliberately tracks the system setting rather than the host
  page's, so a light-only site does not force a white popover onto a dark
  desktop.

- The Apple message list now handles PgUp / PgDown (wide / hardware-keyboard
  layouts): they scroll the list by about one visible page, leaving the
  selection where it is, with a row of overlap for context. If a page lands
  on rows that aren't loaded yet, the fetch is debounced so a fast run of
  presses loads only where you settle. The list tracks its visible row range
  via lightweight onAppear/onDisappear callbacks to size the page.

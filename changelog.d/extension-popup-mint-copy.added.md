- **"Mint + copy address" in the browser extension's toolbar popup.** When a
  sign-up form's email field escapes the detector (a bare `type="text"`
  input with an opaque ASP.NET name, say), the popup now offers the same
  address the in-page popover would have: one click creates a fresh
  address on the chosen apex domain, labelled with the current tab's
  hostname by default, and puts it on the clipboard ready to paste. The
  address is created confirmed rather than pending, since there is no form
  submission for the extension to watch for. The clipboard write is
  authorized inside the click and filled in once the server answers, so it
  survives the async gap on Safari; a Copy button beside the result covers
  the case where the browser refuses the automatic copy anyway.

- Apple: **Message body typed blind under the iPhone keyboard.** Focusing the
  compose body barely scrolled the form, so the keyboard and its
  input-accessory bar covered the Rich Text / Markdown picker, the whole
  formatting toolbar and every character typed — the only way to read the
  message back was to dismiss the keyboard. The body is a `WKWebView`, whose
  focus SwiftUI's focus system never sees, and the UIKit behaviour that used
  to scroll the form for it is not dependable. The composer now brings the
  message row to the top itself, both when the editor takes focus and when
  the keyboard arrives after it.

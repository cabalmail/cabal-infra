- Apple: **One compose model per composer.** Opening a compose window or
  sheet built the compose view model twice — and with it a second WebKit
  rich-text editor — before SwiftUI discarded the extra copy, so every
  composer cost twice the memory and startup work it needed. The model is
  now built once, on every platform.

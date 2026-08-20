- Android: **Reader mode stays dark at phone widths.** The reader
  stylesheet was appended after the author's styles and relied on cascade
  order to win, but that only beats author rules of equal CSS specificity.
  Marketing emails carry `@media (max-width: ...)` class rules with
  `!important` white backgrounds for their "mobile" layout, so the reader
  went light-text-on-white on phones (and narrow windows) while looking
  fine at tablet width. Reader mode now strips author `<style>` blocks and
  stylesheet links outright; inline styles are still overridden by the
  reader stylesheet.

- **Hidden forms no longer draw the extension's attention.** The detector
  filtered inputs by HTML `type`, never by CSS, so a login page that also
  ships a hidden sign-up modal — a common shape — had our listeners and, on
  an ambiguous form, our badge attached to a form the user cannot see. Forms
  hidden with `display: none` or `visibility: hidden` are now skipped, and
  reconsidered the moment the page reveals one.

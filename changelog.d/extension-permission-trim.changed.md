- **Extension permission surface trimmed to storage/identity/history.** The
  private-link interception now rides `tabs.onUpdated` (whose URL visibility
  comes from the extension's own host permission, and closing the redirector
  tab needs no permission at all), so the `tabs` and `webNavigation`
  permissions are no longer requested — a smaller store-review surface with
  identical behavior. A failed private-window open is also logged now
  instead of swallowed. The content script likewise no longer matches
  plain-http sites (localhost excepted, for development): no sign-up form
  should be handed a fresh address over cleartext, and the narrower match
  halves the extension's site-access surface.

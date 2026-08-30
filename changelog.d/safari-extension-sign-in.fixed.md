- **Safari extension sign-in.** Clicking "Sign in with Cabalmail" in the
  Safari extension did nothing: Safari implements no WebExtensions
  `identity` API, which the sign-in flow depended on. Safari now runs the
  Hosted UI in a regular tab redirecting to a new
  `https://admin.<control-domain>/extension-auth` page that the extension
  intercepts and closes automatically (PKCE and the state check carry the
  security, as before); the redirect URI is registered on the Cognito
  client automatically, so Safari needs no per-install configuration.
  Chrome keeps its existing identity-API flow.

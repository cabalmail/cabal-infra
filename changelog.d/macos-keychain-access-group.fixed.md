- The macOS app can store credentials again: it now declares the
  `keychain-access-groups` entitlement so the data-protection keychain has an
  access group on macOS. A sandboxed macOS app with only the prior
  capabilities isn't provisioned with one, so a signed build failed sign-in
  with `Keychain add failed: -34018` (errSecMissingEntitlement). iOS was
  unaffected -- its provisioning profile always supplies the default group.

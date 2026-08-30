- **Scripted browser-extension build and release chores.**
  `scripts/build-extension.sh` builds the Chrome and Safari bundles and
  packages the Web Store zip (stripping the manifest `key` that the store
  rejects); `scripts/extension-redirect-uris.py` derives the OAuth
  redirect URIs from the manifest key and sets
  `TF_VAR_EXTENSION_REDIRECT_URIS` with the escaping `infra.yml` needs;
  `scripts/upload-extension-chrome.sh` uploads and publishes a package
  through the Chrome Web Store API; and
  `scripts/verify-pending-addresses.py` drives the whole pending-address
  lifecycle (create, list, confirm, confirm-again 409, backdate, reap)
  against a live environment.

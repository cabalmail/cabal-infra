- **Scripted browser-extension build and release chores.**
  `scripts/build-extension.sh` builds the Chrome and Safari bundles and
  packages the Web Store zip, refusing one that still carries the manifest
  `key` the store rejects; `scripts/extension-redirect-uris.py` derives the
  Chrome OAuth redirect URIs from that key and sets
  `TF_VAR_EXTENSION_REDIRECT_URIS` with the escaping `infra.yml` needs;
  `scripts/mint-chrome-webstore-token.py` runs the Web Store API
  refresh-token consent round-trip end to end; and
  `scripts/verify-pending-addresses.py` drives the whole pending-address
  lifecycle — create, list, confirm, confirm-again 409, backdate, reap —
  against a live environment.

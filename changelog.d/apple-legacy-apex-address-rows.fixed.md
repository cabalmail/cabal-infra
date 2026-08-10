- Apple: **Address list no longer fails over legacy apex rows.** Addresses
  minted before the no-apex-addressing policy have no `subdomain` attribute,
  and one such row made the whole address list fail to decode — surfacing in
  the compose sheet as "Couldn't load addresses" with a misleading
  key-not-found message. Missing `subdomain` now decodes as empty, and when
  the list truly cannot be decoded the error names the field that actually
  broke.

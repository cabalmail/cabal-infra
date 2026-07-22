- Apple: **Compose From picker no longer blocked by the rich-text
  editor.** The compose sheet loaded its address list only after the
  WebKit editor bridge finished bootstrapping, so a bridge that failed to
  come up left the From menu permanently empty — composing was impossible
  without minting a new address per message. The address list now loads
  concurrently with the editor seed, and a bridge script failure is
  reported in the compose error banner instead of hanging silently.
  `xcodegen generate` also materializes the vendored marked/turndown
  bundles automatically, removing the broken-local-build shape that
  triggered the hang.

/* =========================================================================
   Stable hash-to-swatch mapping for addresses.

   The prototype reserves four per-address swatches (`--accent-1` through
   `--accent-4`) and hardcodes which address gets which. The production app
   derives the swatch index from the address itself so a new address always
   lands on the same colour. djb2 over the lowercased address keeps the
   distribution even and deterministic across reloads.

   The four are the azure, amber, forest and plum accent tokens (tokens.css),
   which carry their own light and dark values; they are used as a small
   identity dot, where the pastel `swatch.*` avatar tokens would vanish
   against the surface.
   ========================================================================= */

export const ADDRESS_SWATCH_COUNT = 4;

export const ADDRESS_SWATCHES = [
  'var(--accent-azure-fg)',  // --accent-1
  'var(--accent-amber-fg)',  // --accent-2
  'var(--accent-forest-fg)', // --accent-3
  'var(--accent-plum-fg)',   // --accent-4
];

export function swatchIndexFor(address) {
  const key = String(address || '').toLowerCase();
  let hash = 5381;
  for (let i = 0; i < key.length; i++) {
    hash = ((hash << 5) + hash + key.charCodeAt(i)) | 0;
  }
  const positive = hash < 0 ? -hash : hash;
  return positive % ADDRESS_SWATCH_COUNT;
}

export function swatchFor(address) {
  return ADDRESS_SWATCHES[swatchIndexFor(address)];
}

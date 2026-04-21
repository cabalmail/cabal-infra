/* =========================================================================
   Stable hash-to-swatch mapping for addresses.

   The prototype reserves four per-address swatches (`--accent-1` through
   `--accent-4`) and hardcodes which address gets which. The production app
   derives the swatch index from the address itself so a new address always
   lands on the same colour. djb2 over the lowercased address keeps the
   distribution even and deterministic across reloads.
   ========================================================================= */

export const ADDRESS_SWATCH_COUNT = 4;

export const ADDRESS_SWATCHES = [
  'oklch(0.52 0.12 250)', // --accent-1 — azure
  'oklch(0.55 0.13 70)',  // --accent-2 — amber
  'oklch(0.45 0.09 150)', // --accent-3 — forest
  'oklch(0.45 0.12 330)', // --accent-4 — plum
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

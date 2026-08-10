/* =========================================================================
   Remote-content policy for the reader's srcdoc iframe.

   Mail HTML can reach a tracking host in more ways than we can name:
   <img src>, srcset, <video poster>, CSS `url()` in a style attribute or a
   <style> block, @import, <link>, <object data>. The iframe sandbox stops
   scripts but not subresource loads, so the block is enforced by a
   Content-Security-Policy <meta> injected at the top of the document head
   rather than by rewriting the one attribute we happen to match.

   The policy denies everything by default and re-admits only what cannot
   phone home: data:/blob: images, inline styles (the reader injects its
   own default <style>, and sender styles must still render), and the
   presigned URLs we mint ourselves for cid: attachments.
   ========================================================================= */

const BLOCK_MARKER = 'data-cabal-block-remote';

/* Contexts in which an http(s) URL causes a fetch. Detection only decides
   whether to offer the "Load images" control — the CSP does the blocking —
   so a miss here is fail-safe (content stays blocked, the banner is
   absent) and a false positive costs only an unnecessary banner. */
const REMOTE_REFERENCE_PATTERNS = [
  /<img\b[^>]*?\bsrc=["']\s*https?:/i,
  /\bsrcset=["'][^"']*https?:/i,
  /\bposter=["']\s*https?:/i,
  /\bbackground=["']\s*https?:/i,
  /url\(\s*["']?\s*https?:/i,
  /@import\s+["']\s*https?:/i,
  /<(?:input|embed|source|track)\b[^>]*?\bsrc=["']\s*https?:/i,
  /<object\b[^>]*?\bdata=["']\s*https?:/i,
  /<link\b[^>]*?\bhref=["']\s*https?:/i,
];

/**
 * True when the HTML references a remote resource that would be fetched on
 * open, by any of the vectors above — not just <img src>.
 *
 * @param {string} html raw message HTML
 * @returns {boolean}
 */
export function hasRemoteContent(html) {
  const source = html || '';
  return REMOTE_REFERENCE_PATTERNS.some((re) => re.test(source));
}

/**
 * The CSP <meta> that blocks every remote subresource in the reader
 * document. Presigned cid: attachment URLs are admitted by origin so
 * inline images still render while remote content is blocked.
 *
 * @param {string[]} allowedImageUrls presigned URLs resolved for cid: refs
 * @returns {string} a <meta http-equiv="Content-Security-Policy"> tag
 */
export function remoteContentBlockMeta(allowedImageUrls = []) {
  const origins = [];
  for (const url of allowedImageUrls) {
    if (!url) continue;
    try {
      const { origin, protocol } = new URL(url);
      if (protocol !== 'http:' && protocol !== 'https:') continue;
      if (!origins.includes(origin)) origins.push(origin);
    } catch {
      /* not a URL we can vouch for: leave it out of the policy */
    }
  }
  const imgSrc = ['data:', 'blob:', ...origins].join(' ');
  const policy = [
    "default-src 'none'",
    `img-src ${imgSrc}`,
    "style-src 'unsafe-inline'",
    'font-src data:',
    'media-src data:',
  ].join('; ');
  return `<meta http-equiv="Content-Security-Policy" content="${policy}" ${BLOCK_MARKER}>`;
}

/**
 * Drop the blocking policy from an already-composed document, for the
 * synchronous half of the user's "Load images" opt-in.
 *
 * @param {string} html composed reader document
 * @returns {string}
 */
export function allowRemoteContent(html) {
  return (html || '').replace(new RegExp(`<meta\\b[^>]*\\b${BLOCK_MARKER}\\b[^>]*>`, 'gi'), '');
}

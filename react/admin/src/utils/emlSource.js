/**
 * Split a raw RFC-822 message into a parsed header list + body text.
 *
 * Used by the reader's View source modal — §4d. We need headers as
 * `[name, value]` pairs so we can colorize the "Name:" span per the
 * design, and we need the body separately so the three segmented-control
 * views (Full / Headers / Body) can render without replaying string-
 * reconstruction tricks.
 *
 * Header continuation lines (RFC 5322 §2.2.3: lines that begin with a
 * space or tab are folded into the preceding header value) are preserved
 * with their leading whitespace so the modal can show them verbatim.
 *
 * Boundary handling: the separator between headers and body is the first
 * CRLF CRLF (or LF LF). Everything before is headers; everything after is
 * body. If no separator exists we treat the whole payload as headers —
 * there is no body.
 */
export function parseEmlSource(raw) {
  const text = (raw || '').replace(/\r\n/g, '\n');
  if (!text) return { headers: [], body: '' };

  const sep = text.indexOf('\n\n');
  const headerSection = sep >= 0 ? text.slice(0, sep) : text;
  const body = sep >= 0 ? text.slice(sep + 2) : '';

  const headers = [];
  for (const line of headerSection.split('\n')) {
    if (/^[ \t]/.test(line) && headers.length > 0) {
      headers[headers.length - 1][1] += `\n${line}`;
      continue;
    }
    const colon = line.indexOf(':');
    if (colon < 0) continue;
    const name = line.slice(0, colon);
    const value = line.slice(colon + 1).replace(/^[ \t]+/, '');
    headers.push([name, value]);
  }

  return { headers, body };
}

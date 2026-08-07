/* =========================================================================
   Relative date formatting for envelope rows, per §4c.

     today      → "3h" (minutes if < 1h)
     yesterday  → "Yesterday"
     this week  → day-of-week ("Thu")
     this year  → "Apr 17"
     older      → "Apr 17 '24"
   ========================================================================= */

const LOCALE = 'en-US';

/* Envelope dates arrive from the API as naive UTC — "2026-07-26 01:16:27",
   no offset and no trailing Z. JS parses a bare date-time as *local* time,
   which shifted every timestamp and relative age by the viewer's UTC
   offset. Match that shape and pin it to UTC; anything that already carries
   a zone (or isn't a date-time at all) goes to Date untouched. */
const NAIVE_DATE_TIME = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?)$/;

export function parseDate(value) {
  if (!value) return null;
  const naive = NAIVE_DATE_TIME.exec(String(value).trim());
  const d = new Date(naive ? `${naive[1]}T${naive[2]}Z` : value);
  return isNaN(d.getTime()) ? null : d;
}

function startOfDay(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

export default function formatDate(iso, now = new Date()) {
  const d = parseDate(iso);
  if (!d) return '';

  const ms = now.getTime() - d.getTime();
  if (ms < 60000) return 'now';

  const mins = Math.floor(ms / 60000);
  if (mins < 60) return `${mins}m`;

  const dayDelta = Math.floor((startOfDay(now) - startOfDay(d)) / 86400000);
  if (dayDelta === 0) {
    const hrs = Math.floor(mins / 60);
    return `${hrs}h`;
  }
  if (dayDelta === 1) return 'Yesterday';
  if (dayDelta < 7) return d.toLocaleDateString(LOCALE, { weekday: 'short' });

  const sameYear = d.getFullYear() === now.getFullYear();
  return d.toLocaleDateString(
    LOCALE,
    sameYear
      ? { month: 'short', day: 'numeric' }
      : { month: 'short', day: 'numeric', year: '2-digit' }
  );
}

export function extractName(fromStr) {
  if (!fromStr) return '';
  const m = /^(.*?)\s*<.*?>\s*$/.exec(fromStr);
  if (m && m[1]) return m[1].replace(/^"|"$/g, '') || fromStr;
  return fromStr;
}

export function extractEmail(fromStr) {
  if (!fromStr) return '';
  const m = /<(.*?)>/.exec(fromStr);
  return m ? m[1] : fromStr;
}

/* Sender domain (lowercased) for a From string, for BIMI lookups.
   "Mary <x@Sub.Example.com>" → "sub.example.com"; "" when there is no @. */
export function domainFor(fromStr) {
  const email = extractEmail(fromStr);
  const at = email.lastIndexOf('@');
  if (at < 0) return '';
  return email.slice(at + 1).replace(/[>\s]+$/, '').trim().toLowerCase();
}

/* Reader-pane timestamp, per §4d: "Friday, Apr 17 · 1:10 PM". */
export function formatReaderTimestamp(iso) {
  const d = parseDate(iso);
  if (!d) return '';
  const datePart = d.toLocaleDateString(LOCALE, {
    weekday: 'long',
    month: 'short',
    day: 'numeric',
  });
  const timePart = d.toLocaleTimeString(LOCALE, {
    hour: 'numeric',
    minute: '2-digit',
  });
  return `${datePart} · ${timePart}`;
}

/* Initials for the header avatar. "Jane Doe" → "JD", "jane@x.com" → "J". */
export function initialsFor(fromStr) {
  if (!fromStr) return '?';
  const name = extractName(fromStr);
  const base = (name || extractEmail(fromStr) || fromStr).trim();
  if (!base) return '?';
  const parts = base.replace(/[<>"]/g, '').split(/[\s.@_-]+/).filter(Boolean);
  if (parts.length === 0) return base.slice(0, 1).toUpperCase();
  if (parts.length === 1) return parts[0].slice(0, 1).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

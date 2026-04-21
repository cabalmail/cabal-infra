/* =========================================================================
   Relative date formatting for envelope rows, per §4c.

     today      → "3h" (minutes if < 1h)
     yesterday  → "Yesterday"
     this week  → day-of-week ("Thu")
     this year  → "Apr 17"
     older      → "Apr 17 '24"
   ========================================================================= */

const LOCALE = 'en-US';

function startOfDay(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

export default function formatDate(iso, now = new Date()) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';

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

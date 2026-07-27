import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import formatDate, {
  extractName,
  extractEmail,
  domainFor,
  parseDate,
  formatReaderTimestamp,
} from './formatDate';

describe('formatDate', () => {
  const now = new Date('2026-04-20T14:00:00');

  it('returns empty string for missing input', () => {
    expect(formatDate(null, now)).toBe('');
    expect(formatDate('', now)).toBe('');
    expect(formatDate('not-a-date', now)).toBe('');
  });

  it('formats recent times in minutes', () => {
    const d = new Date(now.getTime() - 3 * 60000).toISOString();
    expect(formatDate(d, now)).toBe('3m');
  });

  it('formats today in hours', () => {
    const d = new Date(now.getTime() - 3 * 3600000).toISOString();
    expect(formatDate(d, now)).toBe('3h');
  });

  it('labels yesterday as "Yesterday"', () => {
    const yesterday = new Date(now.getTime());
    yesterday.setDate(yesterday.getDate() - 1);
    expect(formatDate(yesterday.toISOString(), now)).toBe('Yesterday');
  });

  it('renders this-week dates as weekday name', () => {
    const threeDaysAgo = new Date(now.getTime());
    threeDaysAgo.setDate(threeDaysAgo.getDate() - 3);
    const out = formatDate(threeDaysAgo.toISOString(), now);
    // weekday short format — three letters
    expect(out).toMatch(/^[A-Z][a-z]{2}$/);
  });

  it('renders same-year older dates as "MMM D"', () => {
    const d = new Date('2026-01-05T12:00:00').toISOString();
    expect(formatDate(d, now)).toMatch(/^[A-Z][a-z]{2} \d+$/);
  });

  it('renders cross-year dates with 2-digit year', () => {
    const d = new Date('2024-08-10T12:00:00').toISOString();
    expect(formatDate(d, now)).toMatch(/^[A-Z][a-z]{2} \d+, \d{2}$/);
  });
});

describe('extractName', () => {
  it('pulls the display name out of a formatted From line', () => {
    expect(extractName('Alice Smith <alice@example.com>')).toBe('Alice Smith');
  });

  it('strips surrounding quotes from quoted display names', () => {
    expect(extractName('"Alice Smith" <alice@example.com>')).toBe('Alice Smith');
  });

  it('falls back to the raw string when no display name is present', () => {
    expect(extractName('alice@example.com')).toBe('alice@example.com');
  });

  it('handles empty input', () => {
    expect(extractName('')).toBe('');
    expect(extractName(null)).toBe('');
  });
});

describe('extractEmail', () => {
  it('returns the bracketed email address', () => {
    expect(extractEmail('Alice <alice@example.com>')).toBe('alice@example.com');
  });

  it('returns the raw string when no brackets present', () => {
    expect(extractEmail('alice@example.com')).toBe('alice@example.com');
  });
});

describe('domainFor', () => {
  it('lowercases the domain from a bracketed address', () => {
    expect(domainFor('Mary <x@Sub.Example.com>')).toBe('sub.example.com');
  });

  it('handles a bare address', () => {
    expect(domainFor('news@chewy.com')).toBe('chewy.com');
  });

  it('returns empty string when there is no @', () => {
    expect(domainFor('Mailer Daemon')).toBe('');
    expect(domainFor('')).toBe('');
  });
});

/* The API sends envelope dates as naive UTC ("2026-07-26 01:16:27"), which
   JS otherwise parses as local time. Pin a non-UTC zone so these assertions
   are meaningful on a UTC CI runner too. */
describe('naive-UTC envelope dates', () => {
  const original = process.env.TZ;
  beforeAll(() => { process.env.TZ = 'America/New_York'; });
  afterAll(() => { process.env.TZ = original; });

  it('runs against a non-UTC zone', () => {
    expect(new Date('2026-07-26T01:16:27Z').getHours()).toBe(21);
  });

  it('reads a naive date-time as UTC, not local', () => {
    expect(parseDate('2026-07-26 01:16:27').getTime())
      .toBe(Date.parse('2026-07-26T01:16:27Z'));
  });

  it('leaves a zoned date-time alone', () => {
    expect(parseDate('2026-07-26T01:16:27Z').getTime())
      .toBe(Date.parse('2026-07-26T01:16:27Z'));
    expect(parseDate('2026-07-25T21:16:27-04:00').getTime())
      .toBe(Date.parse('2026-07-26T01:16:27Z'));
  });

  it('returns null for missing or unparseable input', () => {
    expect(parseDate('')).toBeNull();
    expect(parseDate(null)).toBeNull();
    expect(parseDate('not-a-date')).toBeNull();
  });

  it('renders the reader timestamp in local time', () => {
    // Sent 2026-07-25 21:16 EDT; the naive value is its UTC equivalent.
    expect(formatReaderTimestamp('2026-07-26 01:16:27'))
      .toBe('Saturday, Jul 25 · 9:16 PM');
  });

  it('never dates a just-sent message into the future', () => {
    // 06:21 EDT today, i.e. 10:21 UTC — was rendering as "10:21 AM".
    const now = new Date('2026-07-26T10:26:00Z');
    expect(formatDate('2026-07-26 10:21:00', now)).toBe('5m');
    expect(formatReaderTimestamp('2026-07-26 10:21:00'))
      .toBe('Sunday, Jul 26 · 6:21 AM');
  });

  it('ages a message by its true elapsed time', () => {
    // Sent 2026-07-25 21:16 EDT, read 2026-07-26 06:20 EDT — the previous
    // local day, so "Yesterday". The shifted parse put it at 01:16 *today*
    // and the row read "5h".
    const now = new Date('2026-07-26T10:20:00Z');
    expect(formatDate('2026-07-26 01:16:27', now)).toBe('Yesterday');
  });
});

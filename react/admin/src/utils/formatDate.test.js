import { describe, it, expect } from 'vitest';
import formatDate, { extractName, extractEmail } from './formatDate';

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

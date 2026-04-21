import { describe, it, expect } from 'vitest';
import { parseEmlSource } from './emlSource';

describe('parseEmlSource', () => {
  it('returns empty result for empty input', () => {
    expect(parseEmlSource('')).toEqual({ headers: [], body: '' });
    expect(parseEmlSource(null)).toEqual({ headers: [], body: '' });
  });

  it('splits headers from body at the first blank line', () => {
    const raw = 'From: a@b.com\r\nSubject: hi\r\n\r\nBody line 1\r\nBody line 2';
    const { headers, body } = parseEmlSource(raw);
    expect(headers).toEqual([
      ['From', 'a@b.com'],
      ['Subject', 'hi'],
    ]);
    expect(body).toBe('Body line 1\nBody line 2');
  });

  it('folds continuation lines into the preceding header value', () => {
    const raw = 'Received: from mx1\n\tby mx2\n\tfor <you@host>;\nDate: now\n\nbody';
    const { headers, body } = parseEmlSource(raw);
    expect(headers).toEqual([
      ['Received', 'from mx1\n\tby mx2\n\tfor <you@host>;'],
      ['Date', 'now'],
    ]);
    expect(body).toBe('body');
  });

  it('treats a payload with no blank separator as headers-only', () => {
    const { headers, body } = parseEmlSource('From: a@b\nSubject: s');
    expect(headers).toEqual([['From', 'a@b'], ['Subject', 's']]);
    expect(body).toBe('');
  });

  it('preserves colons inside header values', () => {
    const { headers } = parseEmlSource('Date: Thu, 17 Apr 2025 12:34:56 +0000\n\n');
    expect(headers).toEqual([['Date', 'Thu, 17 Apr 2025 12:34:56 +0000']]);
  });
});

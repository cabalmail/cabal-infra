import { describe, it, expect, vi, beforeEach } from 'vitest';
import { fetchBimi, peekBimi, _resetBimiCache } from './bimiCache';

beforeEach(() => {
  _resetBimiCache();
});

describe('bimiCache', () => {
  it('peek is undefined before a domain resolves', () => {
    expect(peekBimi('unknown.com')).toBeUndefined();
  });

  it('resolves and caches a logo url', async () => {
    const api = { getBimiUrl: vi.fn().mockResolvedValue({ data: { url: 'https://x/logo.png' } }) };
    expect(await fetchBimi(api, 'chewy.com')).toBe('https://x/logo.png');
    expect(peekBimi('chewy.com')).toBe('https://x/logo.png');
  });

  it('coalesces concurrent lookups for the same domain', async () => {
    const api = { getBimiUrl: vi.fn().mockResolvedValue({ data: { url: 'u' } }) };
    const [a, b] = await Promise.all([fetchBimi(api, 'd.com'), fetchBimi(api, 'd.com')]);
    expect(a).toBe('u');
    expect(b).toBe('u');
    expect(api.getBimiUrl).toHaveBeenCalledTimes(1);
  });

  it('caches a null (no record) result and does not refetch', async () => {
    const api = { getBimiUrl: vi.fn().mockResolvedValue({ data: { url: null } }) };
    expect(await fetchBimi(api, 'no.com')).toBeNull();
    expect(await fetchBimi(api, 'no.com')).toBeNull();
    expect(api.getBimiUrl).toHaveBeenCalledTimes(1);
    expect(peekBimi('no.com')).toBeNull();
  });

  it('caches null on request error', async () => {
    const api = { getBimiUrl: vi.fn().mockRejectedValue(new Error('boom')) };
    expect(await fetchBimi(api, 'err.com')).toBeNull();
    expect(peekBimi('err.com')).toBeNull();
  });

  it('resolves null when the api has no getBimiUrl', async () => {
    expect(await fetchBimi({}, 'm.com')).toBeNull();
  });

  it('resolves null for an empty domain without calling the api', async () => {
    const api = { getBimiUrl: vi.fn() };
    expect(await fetchBimi(api, '')).toBeNull();
    expect(api.getBimiUrl).not.toHaveBeenCalled();
  });
});

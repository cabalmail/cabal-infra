import { describe, it, expect, vi, beforeEach } from 'vitest';
import axios from 'axios';
import ApiClient from './ApiClient';

// ApiClient calls axios.get/.put/.delete/.post directly; stub them so we can
// inspect the request config (specifically the per-call `timeout`) without
// hitting the network.
vi.mock('axios', () => ({
  default: {
    get: vi.fn().mockResolvedValue({ data: {} }),
    put: vi.fn().mockResolvedValue({ data: {} }),
    post: vi.fn().mockResolvedValue({ data: {} }),
    delete: vi.fn().mockResolvedValue({ data: {} }),
  },
}));

describe('ApiClient.getEnvelopes timeout', () => {
  let api;

  beforeEach(() => {
    vi.clearAllMocks();
    api = new ApiClient('https://api.example', 'token', 'host');
  });

  // Issue the request for `count` UIDs and return the timeout axios was handed.
  function timeoutFor(count) {
    api.getEnvelopes('INBOX', Array.from({ length: count }, (_, i) => i + 1));
    const config = axios.get.mock.calls.at(-1)[1];
    return config.timeout;
  }

  it('holds the 10s floor for a single envelope (overlay fetch)', () => {
    expect(timeoutFor(1)).toBe(10000);
  });

  it('holds the 10s floor for a PAGE_SIZE page so small fetches are unaffected', () => {
    expect(timeoutFor(30)).toBe(10000);
  });

  it('scales proportionally with the batch size past the floor', () => {
    // 250 UIDs * 100ms = 25000ms, above the floor and below the ceiling.
    expect(timeoutFor(250)).toBe(25000);
  });

  it('clamps to the 30s ceiling for very large batches', () => {
    expect(timeoutFor(5000)).toBe(30000);
  });
});

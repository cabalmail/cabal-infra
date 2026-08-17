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

describe('per-user list caches', () => {
  // Minimal JWT: ApiClient only reads the payload's cognito:username.
  function fakeJwt(username) {
    return `header.${btoa(JSON.stringify({ 'cognito:username': username }))}.sig`;
  }

  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
  });

  it('caches the folder list per user and refetches for a different user', async () => {
    const alice = new ApiClient('https://api.example', fakeJwt('alice'), 'host');
    await alice.getFolderList();
    expect(axios.get).toHaveBeenCalledTimes(1);

    // Same user: served from cache, no second request.
    await alice.getFolderList();
    expect(axios.get).toHaveBeenCalledTimes(1);

    // Different user on the same browser: must hit the API, not the cache.
    const bob = new ApiClient('https://api.example', fakeJwt('bob'), 'host');
    await bob.getFolderList();
    expect(axios.get).toHaveBeenCalledTimes(2);
  });

  it('caches the address list per user and refetches for a different user', async () => {
    const alice = new ApiClient('https://api.example', fakeJwt('alice'), 'host');
    await alice.getAddresses();
    await alice.getAddresses();
    expect(axios.get).toHaveBeenCalledTimes(1);

    const bob = new ApiClient('https://api.example', fakeJwt('bob'), 'host');
    await bob.getAddresses();
    expect(axios.get).toHaveBeenCalledTimes(2);
  });

  it('invalidates only the owning user\'s cache', async () => {
    const alice = new ApiClient('https://api.example', fakeJwt('alice'), 'host');
    const bob = new ApiClient('https://api.example', fakeJwt('bob'), 'host');
    await alice.getFolderList();
    await bob.getFolderList();
    expect(axios.get).toHaveBeenCalledTimes(2);

    alice.invalidateFolderList();
    await alice.getFolderList();
    expect(axios.get).toHaveBeenCalledTimes(3);

    // Bob's cache survived Alice's invalidation.
    await bob.getFolderList();
    expect(axios.get).toHaveBeenCalledTimes(3);
  });

  it('ignores a legacy unscoped cache entry left by an older build', async () => {
    localStorage.setItem('folder_list', JSON.stringify({ data: { folders: ['Stale'], sub_folders: [] } }));
    const alice = new ApiClient('https://api.example', fakeJwt('alice'), 'host');
    await alice.getFolderList();
    expect(axios.get).toHaveBeenCalledTimes(1);
  });
});

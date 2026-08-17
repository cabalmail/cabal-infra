import { describe, it, expect, beforeEach } from 'vitest';
import { usernameFromToken, listCacheKey, clearListCaches } from './listCache';
import { ADDRESS_LIST, FOLDER_LIST } from '../constants';

// Minimal JWT: only the payload segment matters to the parser.
function fakeJwt(username) {
  return `header.${btoa(JSON.stringify({ 'cognito:username': username }))}.sig`;
}

describe('usernameFromToken', () => {
  it('extracts the cognito:username claim', () => {
    expect(usernameFromToken(fakeJwt('alice'))).toBe('alice');
  });

  it('decodes base64url payloads', () => {
    const payload = btoa(JSON.stringify({ 'cognito:username': 'alice' }))
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    expect(usernameFromToken(`header.${payload}.sig`)).toBe('alice');
  });

  it('returns null for a missing token', () => {
    expect(usernameFromToken(null)).toBeNull();
    expect(usernameFromToken(undefined)).toBeNull();
  });

  it('returns null for an opaque (non-JWT) token', () => {
    expect(usernameFromToken('not-a-jwt')).toBeNull();
  });
});

describe('listCacheKey', () => {
  it('scopes the key to the token user', () => {
    expect(listCacheKey(FOLDER_LIST, fakeJwt('alice'))).toBe(`${FOLDER_LIST}:alice`);
    expect(listCacheKey(ADDRESS_LIST, fakeJwt('bob'))).toBe(`${ADDRESS_LIST}:bob`);
  });

  it('falls back to the bare key when the user is unknown', () => {
    expect(listCacheKey(FOLDER_LIST, 'garbage')).toBe(FOLDER_LIST);
  });
});

describe('clearListCaches', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('removes scoped and legacy unscoped list caches, leaving other keys', () => {
    localStorage.setItem(FOLDER_LIST, '{}');
    localStorage.setItem(`${FOLDER_LIST}:alice`, '{}');
    localStorage.setItem(ADDRESS_LIST, '{}');
    localStorage.setItem(`${ADDRESS_LIST}:bob`, '{}');
    localStorage.setItem('state', '{"view":"Email"}');

    clearListCaches();

    expect(localStorage.getItem(FOLDER_LIST)).toBeNull();
    expect(localStorage.getItem(`${FOLDER_LIST}:alice`)).toBeNull();
    expect(localStorage.getItem(ADDRESS_LIST)).toBeNull();
    expect(localStorage.getItem(`${ADDRESS_LIST}:bob`)).toBeNull();
    expect(localStorage.getItem('state')).toBe('{"view":"Email"}');
  });

  // Before #1117 this suite asserted the opposite for the bare collapse
  // keys — that the sweep left them alone. It now takes the unscoped ones,
  // which predate per-user scoping and carry the previous account's rail
  // layout (and its folder names). The scoped ones stay: collapse state is
  // a per-user preference, not a cache, and must survive its own owner's
  // logout.
  it('removes unscoped folder-collapse state but keeps each user\'s scoped copy', () => {
    localStorage.setItem('folder_collapsed_sub', 'true');
    localStorage.setItem('folder_collapsed_all', 'true');
    localStorage.setItem('folder_collapsed_paths', '["Receipts"]');
    localStorage.setItem('folder_collapsed_sub:alice', 'true');
    localStorage.setItem('folder_collapsed_paths:alice', '["Receipts"]');

    clearListCaches();

    expect(localStorage.getItem('folder_collapsed_sub')).toBeNull();
    expect(localStorage.getItem('folder_collapsed_all')).toBeNull();
    expect(localStorage.getItem('folder_collapsed_paths')).toBeNull();
    expect(localStorage.getItem('folder_collapsed_sub:alice')).toBe('true');
    expect(localStorage.getItem('folder_collapsed_paths:alice')).toBe('["Receipts"]');
  });
});

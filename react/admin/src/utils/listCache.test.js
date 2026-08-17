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
    localStorage.setItem('folder_collapsed_sub', 'true');

    clearListCaches();

    expect(localStorage.getItem(FOLDER_LIST)).toBeNull();
    expect(localStorage.getItem(`${FOLDER_LIST}:alice`)).toBeNull();
    expect(localStorage.getItem(ADDRESS_LIST)).toBeNull();
    expect(localStorage.getItem(`${ADDRESS_LIST}:bob`)).toBeNull();
    expect(localStorage.getItem('state')).toBe('{"view":"Email"}');
    expect(localStorage.getItem('folder_collapsed_sub')).toBe('true');
  });
});

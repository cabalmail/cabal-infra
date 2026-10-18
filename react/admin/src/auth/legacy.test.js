import { describe, it, expect, beforeEach } from 'vitest';
import { purgeLibraryStorage } from './legacy';

beforeEach(() => {
  window.localStorage.clear();
});

describe('purgeLibraryStorage', () => {
  it("removes every key amazon-cognito-identity-js wrote, for any client and user", () => {
    const keys = [
      'CognitoIdentityServiceProvider.client-a.alice.idToken',
      'CognitoIdentityServiceProvider.client-a.alice.accessToken',
      'CognitoIdentityServiceProvider.client-a.alice.refreshToken',
      'CognitoIdentityServiceProvider.client-a.alice.clockDrift',
      'CognitoIdentityServiceProvider.client-a.LastAuthUser',
      'CognitoIdentityServiceProvider.enroll-client.alice.refreshToken',
    ];
    keys.forEach((k) => window.localStorage.setItem(k, 'x'));
    expect(purgeLibraryStorage()).toBe(keys.length);
    expect(window.localStorage.length).toBe(0);
  });

  it("leaves the app's own keys alone", () => {
    window.localStorage.setItem('state', '{}');
    window.localStorage.setItem('cabalmail.theme.v1', '{}');
    window.localStorage.setItem('notCognitoIdentityServiceProvider.x', 'y');
    window.localStorage.setItem('CognitoIdentityServiceProvider.c.u.idToken', 'x');
    expect(purgeLibraryStorage()).toBe(1);
    expect(Object.keys(window.localStorage).sort())
      .toEqual(['cabalmail.theme.v1', 'notCognitoIdentityServiceProvider.x', 'state']);
  });

  it('copes with no storage, or storage that throws', () => {
    expect(purgeLibraryStorage(null)).toBe(0);
    const broken = { get length() { throw new Error('SecurityError'); } };
    expect(purgeLibraryStorage(broken)).toBe(0);
  });
});

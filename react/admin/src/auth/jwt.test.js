import { describe, it, expect } from 'vitest';
import { decodeJwtPayload, isAdminToken } from './jwt';
import { makeJwt } from '../test/cognito';

describe('decodeJwtPayload', () => {
  it('decodes the payload claims', () => {
    expect(decodeJwtPayload(makeJwt({ sub: 'abc', exp: 1 }))).toEqual({ sub: 'abc', exp: 1 });
  });

  it("decodes base64url's '-' and '_', which bare atob rejects", () => {
    // Three tildes put a '~' on the one byte position whose low six bits
    // encode alone, so the segment carries '-' (index 62); '?' does the
    // same for '_'. An email address can hold either.
    const token = makeJwt({ email: 'a~~~b???@example.com', 'cognito:groups': ['admin'] });
    const segment = token.split('.')[1];
    expect(segment).toMatch(/-/);
    expect(segment).toMatch(/_/);
    // What App.jsx did before: JSON.parse(atob(segment)).
    expect(() => JSON.parse(atob(segment))).toThrow();
    expect(decodeJwtPayload(token).email).toBe('a~~~b???@example.com');
  });

  it('decodes UTF-8 claims', () => {
    expect(decodeJwtPayload(makeJwt({ name: 'Zoë Ångström' })).name).toBe('Zoë Ångström');
  });

  it('returns {} for anything malformed', () => {
    expect(decodeJwtPayload(null)).toEqual({});
    expect(decodeJwtPayload('')).toEqual({});
    expect(decodeJwtPayload('one-segment')).toEqual({});
    expect(decodeJwtPayload('a.!!!.c')).toEqual({});
    expect(decodeJwtPayload(`a.${btoa('[1,2]')}.c`)).toEqual({});
  });
});

describe('isAdminToken', () => {
  it('is true for the admin group, alone or among others', () => {
    expect(isAdminToken(makeJwt({ 'cognito:groups': ['admin'] }))).toBe(true);
    expect(isAdminToken(makeJwt({ 'cognito:groups': ['users', 'admin'] }))).toBe(true);
  });

  it('is false with no groups claim', () => {
    expect(isAdminToken(makeJwt({ sub: 'x' }))).toBe(false);
    expect(isAdminToken('not-a-jwt')).toBe(false);
  });

  it('matches a whole group name, not a substring', () => {
    expect(isAdminToken(makeJwt({ 'cognito:groups': ['nonadmin', 'admin-readonly'] }))).toBe(false);
  });

  it('reads the string renderings admin_limits.is_admin accepts', () => {
    expect(isAdminToken(makeJwt({ 'cognito:groups': 'admin' }))).toBe(true);
    expect(isAdminToken(makeJwt({ 'cognito:groups': 'users,admin' }))).toBe(true);
    expect(isAdminToken(makeJwt({ 'cognito:groups': '[admin users]' }))).toBe(true);
    expect(isAdminToken(makeJwt({ 'cognito:groups': '[nonadmin users]' }))).toBe(false);
    expect(isAdminToken(makeJwt({ 'cognito:groups': 'admin-readonly' }))).toBe(false);
  });
});

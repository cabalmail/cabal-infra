import { describe, it, expect } from 'vitest';
import {
  authState, methodVerdict, hasAuthData,
  AUTH_OK, AUTH_WARNING, AUTH_NOT_VERIFIED,
  VERDICT_OK, VERDICT_BAD, VERDICT_NEUTRAL,
} from './authResults';

describe('authState', () => {
  it('is ok when dmarc passes', () => {
    expect(authState({ spf: 'pass', dkim: 'pass', dmarc: 'pass' })).toBe(AUTH_OK);
    // DMARC is the aggregate verdict — it wins even over individual failures.
    expect(authState({ spf: 'fail', dkim: 'fail', dmarc: 'pass' })).toBe(AUTH_OK);
    expect(authState({ dmarc: 'pass' })).toBe(AUTH_OK);
  });

  it('warns on hard dmarc failure', () => {
    expect(authState({ spf: 'pass', dkim: 'pass', dmarc: 'fail' })).toBe(AUTH_WARNING);
    expect(authState({ dmarc: 'permerror' })).toBe(AUTH_WARNING);
  });

  it('warns when dmarc is absent but spf and dkim both fail', () => {
    expect(authState({ spf: 'fail', dkim: 'fail' })).toBe(AUTH_WARNING);
  });

  it('never renders absent or null data as a pass', () => {
    expect(authState(null)).toBe(AUTH_NOT_VERIFIED);
    expect(authState(undefined)).toBe(AUTH_NOT_VERIFIED);
    expect(authState({})).toBe(AUTH_NOT_VERIFIED);
  });

  it('treats partial methods without a dmarc verdict as not verified', () => {
    // spf/dkim passing alone is not a dmarc pass.
    expect(authState({ spf: 'pass', dkim: 'pass' })).toBe(AUTH_NOT_VERIFIED);
    // A single failure without dmarc is not the both-fail warning case.
    expect(authState({ spf: 'fail' })).toBe(AUTH_NOT_VERIFIED);
    expect(authState({ spf: 'fail', dkim: 'pass' })).toBe(AUTH_NOT_VERIFIED);
  });

  it('leaves the softfail/neutral/none middle ground quiet', () => {
    expect(authState({ spf: 'softfail', dkim: 'none', dmarc: 'none' })).toBe(AUTH_NOT_VERIFIED);
    expect(authState({ dmarc: 'temperror' })).toBe(AUTH_NOT_VERIFIED);
    expect(authState({ dmarc: 'neutral' })).toBe(AUTH_NOT_VERIFIED);
  });
});

describe('methodVerdict', () => {
  it('maps pass to ok', () => {
    expect(methodVerdict('pass')).toBe(VERDICT_OK);
  });

  it('maps fail and permerror to bad', () => {
    expect(methodVerdict('fail')).toBe(VERDICT_BAD);
    expect(methodVerdict('permerror')).toBe(VERDICT_BAD);
  });

  it('maps every other token — and absent — to neutral', () => {
    for (const t of ['none', 'neutral', 'softfail', 'temperror', 'policy']) {
      expect(methodVerdict(t)).toBe(VERDICT_NEUTRAL);
    }
    expect(methodVerdict(undefined)).toBe(VERDICT_NEUTRAL);
    expect(methodVerdict(null)).toBe(VERDICT_NEUTRAL);
  });
});

describe('hasAuthData', () => {
  it('is false for null, undefined, and empty payloads', () => {
    expect(hasAuthData(null)).toBe(false);
    expect(hasAuthData(undefined)).toBe(false);
    expect(hasAuthData({})).toBe(false);
  });

  it('is true when any method was evaluated', () => {
    expect(hasAuthData({ spf: 'pass' })).toBe(true);
    expect(hasAuthData({ dmarc: 'none' })).toBe(true);
    expect(hasAuthData({ spf: 'pass', dkim: 'pass', dmarc: 'pass' })).toBe(true);
  });
});

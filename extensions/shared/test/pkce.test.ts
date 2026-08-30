import { describe, expect, it } from 'vitest';
import { computeCodeChallenge, generateCodeVerifier, generateState } from '../src/auth/pkce';

describe('pkce', () => {
  it('generates verifiers in the RFC 7636 charset and length range', () => {
    for (let i = 0; i < 50; i += 1) {
      const v = generateCodeVerifier();
      expect(v).toMatch(/^[A-Za-z0-9\-._~]{43,128}$/);
    }
  });

  it('computes the S256 challenge for the RFC 7636 appendix B vector', async () => {
    // https://datatracker.ietf.org/doc/html/rfc7636#appendix-B
    const challenge = await computeCodeChallenge(
      'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
    );
    expect(challenge).toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  it('generates distinct states', () => {
    expect(generateState()).not.toBe(generateState());
  });
});

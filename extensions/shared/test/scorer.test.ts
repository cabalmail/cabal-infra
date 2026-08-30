// @vitest-environment jsdom
import { describe, expect, it } from 'vitest';
import { findEmailField, formKey, scoreForm } from '../src/detect/scorer';

function makeForm(html: string, pageUrl = 'https://example.com/'): {
  form: HTMLFormElement;
  ctx: { url: string; document: Document };
} {
  document.body.innerHTML = html;
  const form = document.querySelector('form');
  if (!form) throw new Error('fixture has no form');
  return { form, ctx: { url: pageUrl, document } };
}

describe('scoreForm', () => {
  it('classifies a canonical sign-up form (new-password + confirm + button)', () => {
    const { form, ctx } = makeForm(`
      <form action="/register">
        <input type="email" name="email" />
        <input type="password" name="pw" autocomplete="new-password" />
        <input type="password" name="pw2" autocomplete="new-password" />
        <button type="submit">Create account</button>
      </form>`);
    const score = scoreForm(form, ctx);
    expect(score.classification).toBe('signup');
    expect(score.emailField?.name).toBe('email');
  });

  it('classifies a canonical sign-in form', () => {
    const { form, ctx } = makeForm(
      `
      <form action="/session">
        <input type="email" name="email" />
        <input type="password" name="pw" autocomplete="current-password" />
        <button type="submit">Sign in</button>
      </form>`,
      'https://example.com/login',
    );
    expect(scoreForm(form, ctx).classification).toBe('signin');
  });

  it('classifies a bare email+password form as ambiguous', () => {
    const { form, ctx } = makeForm(`
      <form action="/auth">
        <input type="email" name="email" />
        <input type="password" name="pw" />
        <button type="submit">Continue</button>
      </form>`);
    expect(scoreForm(form, ctx).classification).toBe('ambiguous');
  });

  it('ignores forms without an email field', () => {
    const { form, ctx } = makeForm(`
      <form action="/search">
        <input type="text" name="q" />
        <button>Search</button>
      </form>`);
    expect(scoreForm(form, ctx).classification).toBe('not-an-auth-form');
  });

  it('does not read GET vs POST as a signal', () => {
    const post = makeForm(`
      <form method="post" action="/auth">
        <input type="email" name="email" /><input type="password" name="p" />
        <button>Continue</button>
      </form>`);
    const get = makeForm(`
      <form method="get" action="/auth">
        <input type="email" name="email" /><input type="password" name="p" />
        <button>Continue</button>
      </form>`);
    expect(scoreForm(post.form, post.ctx).score).toBe(scoreForm(get.form, get.ctx).score);
  });

  it('weights sign-up page URL and heading', () => {
    const { form, ctx } = makeForm(
      `
      <h1>Create your account</h1>
      <form action="/api/auth">
        <input type="email" name="email" />
        <input type="password" name="pw" />
        <label><input type="checkbox" name="tos" /> I agree to the Terms of Service</label>
        <button type="submit">Get started</button>
      </form>`,
      'https://example.com/signup',
    );
    const score = scoreForm(form, ctx);
    expect(score.classification).toBe('signup');
    const names = score.signals.map((s) => s.name);
    expect(names).toContain('pageUrl');
    expect(names).toContain('headingText');
    expect(names).toContain('termsCheckbox');
  });

  it('treats a magic-link email-only form as ambiguous, not signup', () => {
    const { form, ctx } = makeForm(`
      <form action="/auth/magic">
        <input type="email" name="email" placeholder="Email address" />
        <button type="submit">Continue with email</button>
      </form>`);
    expect(scoreForm(form, ctx).classification).toBe('ambiguous');
  });

  it('records per-signal contributions for explainability', () => {
    const { form, ctx } = makeForm(`
      <form>
        <input type="email" name="email" />
        <input type="password" autocomplete="new-password" />
        <button>Sign up</button>
      </form>`);
    const score = scoreForm(form, ctx);
    for (const s of score.signals) {
      expect(Math.abs(s.contribution)).toBe(s.weight);
    }
    expect(score.score).toBe(score.signals.reduce((a, s) => a + s.contribution, 0));
  });
});

describe('findEmailField', () => {
  it('falls back to name/placeholder matching on type=text', () => {
    const { form } = makeForm(`
      <form>
        <input type="text" name="user_email" />
        <input type="password" name="pw" />
      </form>`);
    expect(findEmailField(form)?.name).toBe('user_email');
  });

  it('skips hidden and disabled inputs', () => {
    const { form } = makeForm(`
      <form>
        <input type="hidden" name="email" value="tracker@example.com" />
        <input type="email" name="real" disabled />
      </form>`);
    expect(findEmailField(form)).toBeNull();
  });
});

describe('formKey', () => {
  it('prefers id, then name, then a content hash', () => {
    const a = makeForm('<form id="signup"><input name="email" /></form>');
    expect(formKey(a.form)).toBe('id:signup');
    const b = makeForm('<form name="login"><input name="email" /></form>');
    expect(formKey(b.form)).toBe('name:login');
    const c = makeForm('<form action="/x"><input name="email" /></form>');
    expect(formKey(c.form)).toMatch(/^hash:/);
  });

  it('is stable across identical structures and differs across different ones', () => {
    const a = makeForm('<form action="/x"><input name="email" /></form>');
    const keyA = formKey(a.form);
    const b = makeForm('<form action="/x"><input name="email" /></form>');
    expect(formKey(b.form)).toBe(keyA);
    const c = makeForm('<form action="/y"><input name="email" /></form>');
    expect(formKey(c.form)).not.toBe(keyA);
  });
});

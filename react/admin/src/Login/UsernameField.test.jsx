import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/react';
import UsernameField from './UsernameField';

const baseProps = {
  value: '',
  onChange: () => {},
};

describe('UsernameField', () => {
  it('labels the input and wires htmlFor to it', () => {
    const { container } = render(<UsernameField {...baseProps} />);
    const label = container.querySelector('label');
    expect(label.textContent).toBe('Username');
    expect(label.getAttribute('for')).toBe('userName');
    expect(container.querySelector('input').id).toBe('userName');
  });

  it('keeps the identifiers password managers key off on every screen', () => {
    const { container } = render(<UsernameField {...baseProps} />);
    const input = container.querySelector('input');
    expect(input.getAttribute('name')).toBe('userName');
    expect(input.getAttribute('type')).toBe('text');
    expect(input.getAttribute('autocomplete')).toBe('username');
    expect(input.required).toBe(true);
  });

  it('shapes the input for a case-sensitive identifier', () => {
    // A username is not prose: no autocapitalisation, correction or spellcheck.
    const { container } = render(<UsernameField {...baseProps} />);
    const input = container.querySelector('input');
    expect(input.className).toBe('mono');
    expect(input.getAttribute('autocapitalize')).toBe('off');
    expect(input.getAttribute('autocorrect')).toBe('off');
    expect(input.getAttribute('spellcheck')).toBe('false');
  });

  it('renders the auth field wrapper the surrounding form styles expect', () => {
    const { container } = render(<UsernameField {...baseProps} />);
    expect(container.querySelector('.auth__field > .auth__field-header > .auth__field-label'))
      .not.toBeNull();
    expect(container.querySelector('.auth__field > input')).not.toBeNull();
  });

  it('defaults the placeholder to the wording Login and ForgotPassword share', () => {
    const { container } = render(<UsernameField {...baseProps} />);
    expect(container.querySelector('input').getAttribute('placeholder')).toBe('your-username');
  });

  it('lets a caller override the placeholder', () => {
    // SignUp asks the user to pick a username rather than recall one.
    const { container } = render(
      <UsernameField {...baseProps} placeholder="choose-a-username" />,
    );
    expect(container.querySelector('input').getAttribute('placeholder'))
      .toBe('choose-a-username');
  });

  it('shows the caller-supplied value', () => {
    const { container } = render(<UsernameField {...baseProps} value="alice" />);
    expect(container.querySelector('input').value).toBe('alice');
  });

  it('stays controlled when value is undefined', () => {
    const seen = [];
    const onChange = vi.fn((e) => seen.push(e.target.value));
    const { container } = render(
      <UsernameField {...baseProps} value={undefined} onChange={onChange} />,
    );
    const input = container.querySelector('input');
    expect(input.value).toBe('');
    fireEvent.change(input, { target: { value: 'alice' } });
    expect(seen).toEqual(['alice']);
    expect(input.value).toBe('');
  });

  it('renders children below the input and nothing when they are absent', () => {
    const { container } = render(
      <UsernameField {...baseProps}><p className="auth__field-help">3-32 characters.</p></UsernameField>,
    );
    const field = container.querySelector('.auth__field');
    expect(field.children.length).toBe(3);
    expect(field.children[2].textContent).toBe('3-32 characters.');

    const { container: bare } = render(<UsernameField {...baseProps} />);
    expect(bare.querySelector('.auth__field').children.length).toBe(2);
  });
});

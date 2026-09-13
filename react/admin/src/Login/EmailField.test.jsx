import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/react';
import EmailField from './EmailField';

const baseProps = {
  value: '',
  onChange: () => {},
};

describe('EmailField', () => {
  it('labels the input and wires htmlFor to it', () => {
    const { container } = render(<EmailField {...baseProps} />);
    const label = container.querySelector('label');
    expect(label.textContent).toBe('Email address');
    expect(label.getAttribute('for')).toBe('email');
    expect(container.querySelector('input').id).toBe('email');
  });

  it('keeps the identifiers the browser keys saved addresses off on both screens', () => {
    const { container } = render(<EmailField {...baseProps} />);
    const input = container.querySelector('input');
    expect(input.getAttribute('name')).toBe('email');
    expect(input.getAttribute('type')).toBe('email');
    expect(input.getAttribute('autocomplete')).toBe('email');
    expect(input.getAttribute('placeholder')).toBe('you@example.com');
    expect(input.required).toBe(true);
  });

  it('shapes the input for an address rather than prose', () => {
    const { container } = render(<EmailField {...baseProps} />);
    const input = container.querySelector('input');
    expect(input.className).toBe('mono');
    expect(input.getAttribute('autocapitalize')).toBe('off');
    expect(input.getAttribute('autocorrect')).toBe('off');
    expect(input.getAttribute('spellcheck')).toBe('false');
  });

  it('renders no hint beside the label unless one is given', () => {
    const { container } = render(<EmailField {...baseProps} />);
    const header = container.querySelector('.auth__field > .auth__field-header');
    expect(header.children.length).toBe(1);
    expect(container.querySelector('.auth__field-hint')).toBeNull();
  });

  it('renders the hint after the label when given', () => {
    // SignUp explains why it asks for an address at all.
    const { container } = render(
      <EmailField {...baseProps} hint="For verification and recovery" />,
    );
    const header = container.querySelector('.auth__field > .auth__field-header');
    expect(header.children.length).toBe(2);
    expect(header.children[0].tagName).toBe('LABEL');
    expect(header.children[1].className).toBe('auth__field-hint');
    expect(header.children[1].textContent).toBe('For verification and recovery');
  });

  it('shows the caller-supplied value', () => {
    const { container } = render(<EmailField {...baseProps} value="alice@example.net" />);
    expect(container.querySelector('input').value).toBe('alice@example.net');
  });

  it('stays controlled when value is undefined', () => {
    const seen = [];
    const onChange = vi.fn((e) => seen.push(e.target.value));
    const { container } = render(
      <EmailField {...baseProps} value={undefined} onChange={onChange} />,
    );
    const input = container.querySelector('input');
    expect(input.value).toBe('');
    fireEvent.change(input, { target: { value: 'alice@example.net' } });
    expect(seen).toEqual(['alice@example.net']);
    expect(input.value).toBe('');
  });

  it('renders children below the input and nothing when they are absent', () => {
    const { container } = render(
      <EmailField {...baseProps}><p className="auth__field-help">An existing address.</p></EmailField>,
    );
    const field = container.querySelector('.auth__field');
    expect(field.children.length).toBe(3);
    expect(field.children[1].tagName).toBe('INPUT');
    expect(field.children[2].textContent).toBe('An existing address.');

    const { container: bare } = render(<EmailField {...baseProps} />);
    expect(bare.querySelector('.auth__field').children.length).toBe(2);
  });
});

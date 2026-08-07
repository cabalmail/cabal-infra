import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/react';
import VerificationCodeField from './VerificationCodeField';

describe('VerificationCodeField', () => {
  it('labels the input and wires htmlFor to it', () => {
    const { container } = render(
      <VerificationCodeField label="Authentication code" value="" onChange={() => {}} />,
    );
    const label = container.querySelector('label');
    const input = container.querySelector('input');
    expect(label.textContent).toBe('Authentication code');
    expect(label.getAttribute('for')).toBe('verificationCode');
    expect(input.id).toBe('verificationCode');
  });

  it('keeps the autofill and keypad hints password managers key off', () => {
    const { container } = render(
      <VerificationCodeField label="Verification code" value="" onChange={() => {}} />,
    );
    const input = container.querySelector('input');
    expect(input.getAttribute('name')).toBe('verificationCode');
    expect(input.getAttribute('type')).toBe('text');
    expect(input.getAttribute('class')).toBe('mono');
    expect(input.getAttribute('autocomplete')).toBe('one-time-code');
    expect(input.getAttribute('inputmode')).toBe('numeric');
    expect(input.getAttribute('placeholder')).toBe('123456');
    expect(input.required).toBe(true);
  });

  it('renders the auth field wrapper the surrounding form styles expect', () => {
    const { container } = render(
      <VerificationCodeField label="Verification code" value="" onChange={() => {}} />,
    );
    expect(container.querySelector('.auth__field > .auth__field-header > .auth__field-label'))
      .not.toBeNull();
    expect(container.querySelector('.auth__field > input')).not.toBeNull();
  });

  it('stays controlled when value is undefined', () => {
    // Read the value inside the handler: by the time the mock's recorded
    // event is inspected, the controlled input has already snapped back.
    const seen = [];
    const onChange = vi.fn((e) => seen.push(e.target.value));
    const { container } = render(
      <VerificationCodeField label="Verification code" value={undefined} onChange={onChange} />,
    );
    const input = container.querySelector('input');
    expect(input.value).toBe('');
    // The parent owns the value; without a state update the field snaps back.
    fireEvent.change(input, { target: { value: '123456' } });
    expect(onChange).toHaveBeenCalledTimes(1);
    expect(seen).toEqual(['123456']);
    expect(input.value).toBe('');
  });

  it('shows the caller-supplied value', () => {
    const { container } = render(
      <VerificationCodeField label="Verification code" value="123456" onChange={() => {}} />,
    );
    expect(container.querySelector('input').value).toBe('123456');
  });

  it('does not take focus by default', () => {
    const { container } = render(
      <VerificationCodeField label="Verification code" value="" onChange={() => {}} />,
    );
    expect(document.activeElement).not.toBe(container.querySelector('input'));
  });

  it('takes focus on mount when autoFocus is set', () => {
    const { container } = render(
      <VerificationCodeField label="Verification code" value="" onChange={() => {}} autoFocus />,
    );
    expect(document.activeElement).toBe(container.querySelector('input'));
  });
});

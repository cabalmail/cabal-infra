import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/react';
import PasswordField from './PasswordField';

const baseProps = {
  label: 'Password',
  autoComplete: 'current-password',
  value: '',
  onChange: () => {},
  visible: false,
  onToggleVisible: () => {},
};

describe('PasswordField', () => {
  it('labels the input and wires htmlFor to it', () => {
    const { container } = render(<PasswordField {...baseProps} label="New password" />);
    const label = container.querySelector('label');
    expect(label.textContent).toBe('New password');
    expect(label.getAttribute('for')).toBe('password');
    expect(container.querySelector('input').id).toBe('password');
  });

  it('keeps the identifiers password managers key off, with a per-screen autofill hint', () => {
    const { container } = render(
      <PasswordField {...baseProps} autoComplete="new-password" />,
    );
    const input = container.querySelector('input');
    expect(input.getAttribute('name')).toBe('password');
    expect(input.getAttribute('placeholder')).toBe('••••••••');
    expect(input.getAttribute('autocomplete')).toBe('new-password');
    expect(input.required).toBe(true);
  });

  it('renders the auth field wrapper the surrounding form styles expect', () => {
    const { container } = render(<PasswordField {...baseProps} />);
    expect(container.querySelector('.auth__field > .auth__field-header > .auth__field-label'))
      .not.toBeNull();
    expect(container.querySelector('.auth__field > .auth__field-adorn > input')).not.toBeNull();
    expect(container.querySelector('.auth__field-adorn > .auth__field-adorn-btn')).not.toBeNull();
  });

  it('masks the input and offers to show it when visibility is off', () => {
    const { container } = render(<PasswordField {...baseProps} visible={false} />);
    const button = container.querySelector('.auth__field-adorn-btn');
    expect(container.querySelector('input').getAttribute('type')).toBe('password');
    expect(button.getAttribute('aria-label')).toBe('Show password');
    expect(button.textContent).toBe('Show');
    expect(button.getAttribute('type')).toBe('button');
  });

  it('reveals the input and offers to hide it when visibility is on', () => {
    const { container } = render(<PasswordField {...baseProps} visible />);
    const button = container.querySelector('.auth__field-adorn-btn');
    expect(container.querySelector('input').getAttribute('type')).toBe('text');
    expect(button.getAttribute('aria-label')).toBe('Hide password');
    expect(button.textContent).toBe('Hide');
  });

  it('leaves visibility to the caller, who may mirror it onto other inputs', () => {
    // SignUp drives its separate confirm-password input off the same flag,
    // which is why the state lives in the caller and not here.
    const onToggleVisible = vi.fn();
    const { container } = render(
      <PasswordField {...baseProps} onToggleVisible={onToggleVisible} />,
    );
    fireEvent.click(container.querySelector('.auth__field-adorn-btn'));
    expect(onToggleVisible).toHaveBeenCalledTimes(1);
    // No internal state: the field stays masked until the caller says otherwise.
    expect(container.querySelector('input').getAttribute('type')).toBe('password');
  });

  it('stays controlled when value is undefined', () => {
    const seen = [];
    const onChange = vi.fn((e) => seen.push(e.target.value));
    const { container } = render(
      <PasswordField {...baseProps} value={undefined} onChange={onChange} />,
    );
    const input = container.querySelector('input');
    expect(input.value).toBe('');
    fireEvent.change(input, { target: { value: 'hunter2' } });
    expect(seen).toEqual(['hunter2']);
    expect(input.value).toBe('');
  });

  it('shows the caller-supplied value', () => {
    const { container } = render(<PasswordField {...baseProps} value="hunter2" />);
    expect(container.querySelector('input').value).toBe('hunter2');
  });

  it('renders headerHint beside the label and nothing when it is absent', () => {
    const { container } = render(
      <PasswordField {...baseProps} headerHint={<button type="button">Forgot password?</button>} />,
    );
    const header = container.querySelector('.auth__field-header');
    expect(header.children.length).toBe(2);
    expect(header.children[0].tagName).toBe('LABEL');
    expect(header.children[1].textContent).toBe('Forgot password?');

    const { container: bare } = render(<PasswordField {...baseProps} />);
    expect(bare.querySelector('.auth__field-header').children.length).toBe(1);
  });

  it('renders children below the input and nothing when they are absent', () => {
    const { container } = render(
      <PasswordField {...baseProps}><p className="meter">strength</p></PasswordField>,
    );
    const field = container.querySelector('.auth__field');
    expect(field.children.length).toBe(3);
    expect(field.children[2].textContent).toBe('strength');

    const { container: bare } = render(<PasswordField {...baseProps} />);
    expect(bare.querySelector('.auth__field').children.length).toBe(2);
  });
});

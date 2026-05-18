import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import SignUp from './index';
import AuthContext from '../contexts/AuthContext';

const withAuth = (ui) => (
  <AuthContext.Provider value={{ control_domain: 'example.com' }}>
    {ui}
  </AuthContext.Provider>
);

describe('SignUp', () => {
  const defaultProps = {
    onSubmit: vi.fn(),
    onUsernameChange: vi.fn(),
    onPasswordChange: vi.fn(),
    onPhoneChange: vi.fn(),
    onInviteCodeChange: vi.fn(),
    username: '',
    password: '',
    phone: '',
    inviteCode: ''
  };

  const validProps = {
    username: 'alice',
    phone: '+12125551234',
    password: 'correct-horse-battery-staple',
    inviteCode: 'shared-secret',
  };

  it('renders username, phone, invitation code, and password fields', () => {
    render(withAuth(<SignUp {...defaultProps} />));
    expect(screen.getByLabelText('Username')).toBeInTheDocument();
    expect(screen.getByLabelText('Phone number')).toBeInTheDocument();
    expect(screen.getByLabelText('Invitation code')).toBeInTheDocument();
    expect(screen.getByLabelText('Password')).toBeInTheDocument();
    expect(screen.getByLabelText('Confirm password')).toBeInTheDocument();
  });

  it('renders a submit button', () => {
    render(withAuth(<SignUp {...defaultProps} />));
    expect(screen.getByRole('button', { name: 'Create account' })).toBeInTheDocument();
  });

  it('disables submit until all fields are valid', () => {
    render(withAuth(<SignUp {...defaultProps} />));
    expect(screen.getByRole('button', { name: 'Create account' })).toBeDisabled();
  });

  it('calls onPhoneChange when phone input changes', () => {
    const onPhoneChange = vi.fn();
    render(withAuth(<SignUp {...defaultProps} onPhoneChange={onPhoneChange} />));
    fireEvent.change(screen.getByLabelText('Phone number'), { target: { value: '+1555' } });
    expect(onPhoneChange).toHaveBeenCalledTimes(1);
  });

  it('calls onSubmit when the fully-valid form is submitted', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(withAuth(<SignUp {...defaultProps} {...validProps} onSubmit={onSubmit} />));
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Create account' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it('keeps submit disabled when invitation code is empty', () => {
    render(withAuth(
      <SignUp
        {...defaultProps}
        {...validProps}
        inviteCode=""
      />
    ));
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    expect(screen.getByRole('button', { name: 'Create account' })).toBeDisabled();
  });
});

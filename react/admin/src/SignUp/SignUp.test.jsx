import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import SignUp from './index';
import AuthContext from '../contexts/AuthContext';

const withAuth = (ui, { invitation_required = false } = {}) => (
  <AuthContext.Provider value={{ control_domain: 'example.com', invitation_required }}>
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

  it('renders username, phone, and password fields', () => {
    render(withAuth(<SignUp {...defaultProps} />));
    expect(screen.getByLabelText('Username')).toBeInTheDocument();
    expect(screen.getByLabelText('Phone number')).toBeInTheDocument();
    expect(screen.getByLabelText('Password')).toBeInTheDocument();
    expect(screen.getByLabelText('Confirm password')).toBeInTheDocument();
  });

  it('hides the invitation code field when not required', () => {
    render(withAuth(<SignUp {...defaultProps} />));
    expect(screen.queryByLabelText('Invitation code')).toBeNull();
  });

  it('shows the invitation code field when required', () => {
    render(withAuth(<SignUp {...defaultProps} />, { invitation_required: true }));
    expect(screen.getByLabelText('Invitation code')).toBeInTheDocument();
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

  it('calls onSubmit when the fully-valid form is submitted (gate off)', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(withAuth(<SignUp {...defaultProps} {...validProps} inviteCode="" onSubmit={onSubmit} />));
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    fireEvent.click(screen.getByRole('checkbox'));
    fireEvent.click(screen.getByRole('button', { name: 'Create account' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it('calls onSubmit when the fully-valid form is submitted (gate on)', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(withAuth(
      <SignUp {...defaultProps} {...validProps} onSubmit={onSubmit} />,
      { invitation_required: true }
    ));
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    fireEvent.click(screen.getByRole('checkbox'));
    fireEvent.click(screen.getByRole('button', { name: 'Create account' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it('renders a mandatory SMS consent checkbox, unchecked by default', () => {
    render(withAuth(<SignUp {...defaultProps} />));
    const consent = screen.getByRole('checkbox');
    expect(consent).toBeInTheDocument();
    expect(consent).not.toBeChecked();
  });

  it('keeps submit disabled until the SMS consent box is checked', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(withAuth(<SignUp {...defaultProps} {...validProps} inviteCode="" onSubmit={onSubmit} />));
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    // Every other field is valid; the consent gate alone holds submit closed.
    expect(screen.getByRole('button', { name: 'Create account' })).toBeDisabled();
    fireEvent.click(screen.getByRole('checkbox'));
    expect(screen.getByRole('button', { name: 'Create account' })).toBeEnabled();
  });

  it('keeps submit disabled when invitation code is empty and required', () => {
    render(withAuth(
      <SignUp
        {...defaultProps}
        {...validProps}
        inviteCode=""
      />,
      { invitation_required: true }
    ));
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    expect(screen.getByRole('button', { name: 'Create account' })).toBeDisabled();
  });
});

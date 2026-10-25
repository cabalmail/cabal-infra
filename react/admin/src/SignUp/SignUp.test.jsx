import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import SignUp from './index';
import AuthContext from '../contexts/AuthContext';
import { PASSWORD_HINT } from './signUpFields';

const withAuth = (
  ui,
  { invitation_required = false, sms_enabled = true } = {}
) => (
  <AuthContext.Provider
    value={{ control_domain: 'example.com', invitation_required, sms_enabled }}
  >
    {ui}
  </AuthContext.Provider>
);

describe('SignUp', () => {
  const defaultProps = {
    onSubmit: vi.fn(),
    onUsernameChange: vi.fn(),
    onEmailChange: vi.fn(),
    onPasswordChange: vi.fn(),
    onPhoneChange: vi.fn(),
    onInviteCodeChange: vi.fn(),
    username: '',
    email: '',
    password: '',
    phone: '',
    inviteCode: ''
  };

  const validProps = {
    username: 'alice',
    email: 'alice@example.net',
    phone: '+12125551234',
    password: 'correct-horse-battery-staple',
    inviteCode: 'shared-secret',
  };

  it('renders username, email, phone, and password fields', () => {
    render(withAuth(<SignUp {...defaultProps} />));
    expect(screen.getByLabelText('Username')).toBeInTheDocument();
    expect(screen.getByLabelText('Email address')).toBeInTheDocument();
    expect(screen.getByLabelText('Phone number')).toBeInTheDocument();
    expect(screen.getByLabelText('Password')).toBeInTheDocument();
    expect(screen.getByLabelText('Confirm password')).toBeInTheDocument();
  });

  it('calls onEmailChange when email input changes', () => {
    const onEmailChange = vi.fn();
    render(withAuth(<SignUp {...defaultProps} onEmailChange={onEmailChange} />));
    fireEvent.change(screen.getByLabelText('Email address'), {
      target: { value: 'a@b.co' },
    });
    expect(onEmailChange).toHaveBeenCalledTimes(1);
  });

  it('keeps submit disabled when the email is invalid', () => {
    render(withAuth(<SignUp {...defaultProps} {...validProps} email="not-an-email" inviteCode="" />));
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    fireEvent.click(screen.getByRole('checkbox'));
    expect(screen.getByRole('button', { name: 'Create account' })).toBeDisabled();
  });

  it('keeps submit disabled for a username with no letter', () => {
    const { rerender } = render(withAuth(
      <SignUp {...defaultProps} {...validProps} username="12345" inviteCode="" />
    ));
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    fireEvent.click(screen.getByRole('checkbox'));
    expect(screen.getByRole('button', { name: 'Create account' })).toBeDisabled();
    rerender(withAuth(
      <SignUp {...defaultProps} {...validProps} username="12345a" inviteCode="" />
    ));
    expect(screen.getByRole('button', { name: 'Create account' })).toBeEnabled();
  });

  it('renders the email field even when SMS is off', () => {
    render(withAuth(<SignUp {...defaultProps} />, { sms_enabled: false }));
    expect(screen.getByLabelText('Email address')).toBeInTheDocument();
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

  // Issue #2141: the field used to accept `/^\+?[0-9\s-]{7,}$/`, so a local
  // number with no country code enabled Create account and was then refused
  // by Cognito as an unexplained "Registration failed.". It is validated as
  // E.164 now — the shape the pool's `phone_number` attribute requires.
  describe('the phone number is validated as E.164 (#2141)', () => {
    const enable = () => fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });

    it('keeps submit disabled without a country code', () => {
      render(withAuth(<SignUp {...defaultProps} {...validProps} phone="555-123-4567" inviteCode="" />));
      enable();
      fireEvent.click(screen.getByLabelText(/I agree to receive/));
      expect(screen.getByRole('button', { name: 'Create account' })).toBeDisabled();
    });

    it('accepts the punctuation people type around a country code', () => {
      // The report's own example. It is normalized on the way to Cognito,
      // so the form has no reason to turn it away.
      render(withAuth(<SignUp {...defaultProps} {...validProps} phone="+1 555 123 4567" inviteCode="" />));
      enable();
      fireEvent.click(screen.getByLabelText(/I agree to receive/));
      expect(screen.getByRole('button', { name: 'Create account' })).toBeEnabled();
    });

    it('teaches the shape it wants rather than one the pool refuses', () => {
      render(withAuth(<SignUp {...defaultProps} />));
      const field = screen.getByLabelText('Phone number');
      expect(field.placeholder).toBe('+15551234567');
      expect(field.placeholder).not.toMatch(/\s/);
    });
  });

  // The hint used to recommend a passphrase, which is what the pool refuses:
  // no `password_policy` is set, so Cognito's default wants upper and lower
  // case, a digit and a symbol (#2141).
  it('tells the user which character classes the pool wants', () => {
    render(withAuth(<SignUp {...defaultProps} />));
    expect(screen.getByText(PASSWORD_HINT)).toBeInTheDocument();
    expect(screen.queryByText(/passphrase/i)).not.toBeInTheDocument();
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

  // With SMS on the phone verifies and recovers the account, so the
  // recovery email is optional: Cabalmail can be someone's only email.
  it('submits without an email when SMS is on', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(withAuth(<SignUp {...defaultProps} {...validProps} email="" inviteCode="" onSubmit={onSubmit} />));
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    fireEvent.click(screen.getByRole('checkbox'));
    expect(screen.getByRole('button', { name: 'Create account' })).toBeEnabled();
    fireEvent.click(screen.getByRole('button', { name: 'Create account' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it('marks the email optional when SMS is on', () => {
    render(withAuth(<SignUp {...defaultProps} />));
    expect(screen.getByLabelText('Email address').required).toBe(false);
    expect(screen.getByText('Optional, for recovery')).toBeInTheDocument();
    expect(screen.getByLabelText('Phone number').required).toBe(true);
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

  describe('with sms_enabled=false', () => {
    it('hides the phone-number field and SMS consent checkbox', () => {
      render(withAuth(<SignUp {...defaultProps} />, { sms_enabled: false }));
      expect(screen.queryByLabelText('Phone number')).toBeNull();
      expect(screen.queryByRole('checkbox')).toBeNull();
    });

    // The email is the only channel that can verify or recover the account.
    it('requires the email when SMS is off', () => {
      const { rerender } = render(withAuth(
        <SignUp {...defaultProps} {...validProps} email="" phone="" inviteCode="" />,
        { sms_enabled: false }
      ));
      fireEvent.change(screen.getByLabelText('Confirm password'), {
        target: { value: validProps.password },
      });
      expect(screen.getByLabelText('Email address').required).toBe(true);
      expect(screen.getByRole('button', { name: 'Create account' })).toBeDisabled();
      rerender(withAuth(
        <SignUp {...defaultProps} {...validProps} phone="" inviteCode="" />,
        { sms_enabled: false }
      ));
      expect(screen.getByRole('button', { name: 'Create account' })).toBeEnabled();
    });

    it('submits without a phone number or consent when SMS is off', () => {
      const onSubmit = vi.fn(e => e.preventDefault());
      render(withAuth(
        <SignUp
          {...defaultProps}
          {...validProps}
          phone=""
          inviteCode=""
          onSubmit={onSubmit}
        />,
        { sms_enabled: false }
      ));
      fireEvent.change(screen.getByLabelText('Confirm password'), {
        target: { value: validProps.password },
      });
      expect(screen.getByRole('button', { name: 'Create account' })).toBeEnabled();
      fireEvent.click(screen.getByRole('button', { name: 'Create account' }));
      expect(onSubmit).toHaveBeenCalledTimes(1);
    });
  });
});

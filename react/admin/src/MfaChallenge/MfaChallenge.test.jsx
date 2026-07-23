import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import MfaChallenge from './index';
import AuthContext from '../contexts/AuthContext';

const withAuth = (ui) => (
  <AuthContext.Provider value={{ control_domain: 'example.com' }}>
    {ui}
  </AuthContext.Provider>
);

describe('MfaChallenge', () => {
  const defaultProps = {
    onSubmit: vi.fn(e => e.preventDefault()),
    onCodeChange: vi.fn(),
    code: '',
    onBackToSignIn: vi.fn(),
  };

  it('renders a code field and Verify button', () => {
    render(withAuth(<MfaChallenge {...defaultProps} />));
    expect(screen.getByLabelText('Authentication code')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Verify' })).toBeInTheDocument();
  });

  it('describes the authenticator app for TOTP challenges', () => {
    render(withAuth(<MfaChallenge {...defaultProps} mfaType="totp" />));
    expect(
      screen.getByText('Enter the 6-digit code from your authenticator app.')
    ).toBeInTheDocument();
  });

  it('describes SMS for SMS challenges', () => {
    render(withAuth(<MfaChallenge {...defaultProps} mfaType="sms" />));
    expect(
      screen.getByText('Enter the code we just sent to your phone.')
    ).toBeInTheDocument();
  });

  it('submits the form', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(withAuth(<MfaChallenge {...defaultProps} code="123456" onSubmit={onSubmit} />));
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it('calls onCodeChange as the user types', () => {
    const onCodeChange = vi.fn();
    render(withAuth(<MfaChallenge {...defaultProps} onCodeChange={onCodeChange} />));
    fireEvent.change(screen.getByLabelText('Authentication code'), {
      target: { value: '1' },
    });
    expect(onCodeChange).toHaveBeenCalledTimes(1);
  });
});

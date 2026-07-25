import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import MfaSetup from './index';
import AuthContext from '../contexts/AuthContext';

const withAuth = (ui) => (
  <AuthContext.Provider value={{ control_domain: 'example.com' }}>
    {ui}
  </AuthContext.Provider>
);

describe('MfaSetup', () => {
  const defaultProps = {
    userName: 'claude',
    secret: null,
    busy: false,
    code: '',
    onBegin: vi.fn(),
    onCodeChange: vi.fn(),
    onSubmit: vi.fn(e => e.preventDefault()),
    onCancel: vi.fn(),
  };

  it('offers setup without leaking Cognito internals', () => {
    render(withAuth(<MfaSetup {...defaultProps} />));
    expect(
      screen.getByRole('button', { name: 'Set up authenticator app' })
    ).toBeInTheDocument();
    // The stale admin-era copy (#770) and the raw trigger name must
    // not appear anywhere on the locked-out screen.
    expect(screen.queryByText(/admin accounts/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/PreTokenGeneration/)).not.toBeInTheDocument();
  });

  it('starts enrollment from the offer button', () => {
    const onBegin = vi.fn();
    render(withAuth(<MfaSetup {...defaultProps} onBegin={onBegin} />));
    fireEvent.click(screen.getByRole('button', { name: 'Set up authenticator app' }));
    expect(onBegin).toHaveBeenCalledTimes(1);
  });

  it('shows the QR, manual key, and code form once a secret exists', () => {
    render(withAuth(<MfaSetup {...defaultProps} secret="SECRETKEY234567" />));
    expect(screen.getByLabelText('TOTP enrollment QR code')).toBeInTheDocument();
    expect(screen.getByText('SECRETKEY234567')).toBeInTheDocument();
    expect(screen.getByLabelText('Code from your app')).toBeInTheDocument();
  });

  it('keeps Confirm disabled until six digits are entered', () => {
    const { rerender } = render(
      withAuth(<MfaSetup {...defaultProps} secret="SECRETKEY234567" code="123" />)
    );
    expect(screen.getByRole('button', { name: 'Confirm' })).toBeDisabled();
    rerender(
      withAuth(<MfaSetup {...defaultProps} secret="SECRETKEY234567" code="123456" />)
    );
    expect(screen.getByRole('button', { name: 'Confirm' })).toBeEnabled();
  });

  it('submits the confirmation form', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(withAuth(
      <MfaSetup {...defaultProps} secret="SECRETKEY234567" code="123456" onSubmit={onSubmit} />
    ));
    fireEvent.click(screen.getByRole('button', { name: 'Confirm' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it('offers a way back to sign-in from both phases', () => {
    const onCancel = vi.fn();
    const { rerender } = render(withAuth(<MfaSetup {...defaultProps} onCancel={onCancel} />));
    fireEvent.click(screen.getByText('Back to sign in'));
    rerender(withAuth(
      <MfaSetup {...defaultProps} secret="SECRETKEY234567" onCancel={onCancel} />
    ));
    fireEvent.click(screen.getByText('Back to sign in'));
    expect(onCancel).toHaveBeenCalledTimes(2);
  });
});

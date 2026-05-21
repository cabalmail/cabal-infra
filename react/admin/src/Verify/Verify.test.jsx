import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import Verify from './index';
import AuthContext from '../contexts/AuthContext';

const withAuth = (ui) => (
  <AuthContext.Provider value={{ control_domain: 'example.com' }}>
    {ui}
  </AuthContext.Provider>
);

describe('Verify', () => {
  const baseProps = {
    onSubmit: vi.fn(e => e.preventDefault()),
    onCodeChange: vi.fn(),
    code: '',
  };

  it('renders the verification code field and primary button', () => {
    render(withAuth(<Verify {...baseProps} />));
    expect(screen.getByLabelText('Verification code')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Verify' })).toBeInTheDocument();
  });

  it('does not render the resend control when onResend is not provided', () => {
    render(withAuth(<Verify {...baseProps} />));
    expect(screen.queryByRole('button', { name: /resend/i })).not.toBeInTheDocument();
  });

  it('renders a clickable resend button at rest', () => {
    const onResend = vi.fn();
    render(withAuth(<Verify {...baseProps} onResend={onResend} />));
    const btn = screen.getByRole('button', { name: 'Resend code' });
    expect(btn).toBeEnabled();
    fireEvent.click(btn);
    expect(onResend).toHaveBeenCalledTimes(1);
  });

  it('shows a disabled "Sending..." button while a request is in flight', () => {
    render(withAuth(<Verify {...baseProps} onResend={vi.fn()} resendInFlight={true} />));
    const btn = screen.getByRole('button', { name: /sending/i });
    expect(btn).toBeDisabled();
    expect(screen.queryByRole('button', { name: 'Resend code' })).not.toBeInTheDocument();
  });

  it('shows a lockout message in seconds when resendLocked is true', () => {
    render(withAuth(
      <Verify
        {...baseProps}
        onResend={vi.fn()}
        resendLocked={true}
        resendLockoutRemaining={45}
      />,
    ));
    expect(screen.getByText(/Too many resend attempts.*about 45 seconds/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /resend|sending/i })).not.toBeInTheDocument();
  });

  it('formats lockout remaining in minutes when over 60 seconds', () => {
    render(withAuth(
      <Verify
        {...baseProps}
        onResend={vi.fn()}
        resendLocked={true}
        resendLockoutRemaining={59 * 60}
      />,
    ));
    expect(screen.getByText(/Too many resend attempts.*about 59 minutes/i)).toBeInTheDocument();
  });
});

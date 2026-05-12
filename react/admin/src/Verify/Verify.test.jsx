import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import Verify from './index';

describe('Verify', () => {
  const baseProps = {
    onSubmit: vi.fn(e => e.preventDefault()),
    onCodeChange: vi.fn(),
    code: '',
  };

  it('renders the verification code field and primary button', () => {
    render(<Verify {...baseProps} />);
    expect(screen.getByLabelText('Verification code')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Verify' })).toBeInTheDocument();
  });

  it('does not render the resend control when onResend is not provided', () => {
    render(<Verify {...baseProps} />);
    expect(screen.queryByRole('button', { name: /resend/i })).not.toBeInTheDocument();
  });

  it('renders a clickable resend button when cooldown is 0 and not locked', () => {
    const onResend = vi.fn();
    render(<Verify {...baseProps} onResend={onResend} resendCooldown={0} resendLocked={false} />);
    const btn = screen.getByRole('button', { name: 'Resend code' });
    expect(btn).toBeEnabled();
    fireEvent.click(btn);
    expect(onResend).toHaveBeenCalledTimes(1);
  });

  it('shows the countdown when cooldown > 0', () => {
    render(
      <Verify
        {...baseProps}
        onResend={vi.fn()}
        resendCooldown={42}
        resendLocked={false}
      />,
    );
    expect(screen.getByText(/Resend available in 42s/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Resend code' })).not.toBeInTheDocument();
  });

  it('shows a lockout message in seconds when resendLocked is true', () => {
    render(
      <Verify
        {...baseProps}
        onResend={vi.fn()}
        resendCooldown={0}
        resendLocked={true}
        resendLockoutRemaining={45}
      />,
    );
    expect(screen.getByText(/Too many resend attempts.*45 seconds/i)).toBeInTheDocument();
  });

  it('formats lockout remaining in minutes when over 60 seconds', () => {
    render(
      <Verify
        {...baseProps}
        onResend={vi.fn()}
        resendCooldown={0}
        resendLocked={true}
        resendLockoutRemaining={59 * 60}
      />,
    );
    expect(screen.getByText(/Too many resend attempts.*59 minutes/i)).toBeInTheDocument();
  });
});

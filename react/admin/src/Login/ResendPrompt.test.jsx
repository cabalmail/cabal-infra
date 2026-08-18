import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import ResendPrompt from './ResendPrompt';

describe('ResendPrompt', () => {
  it('renders nothing when there is no onResend handler', () => {
    const { container } = render(<ResendPrompt />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders a clickable resend button at rest', () => {
    const onResend = vi.fn();
    render(<ResendPrompt onResend={onResend} />);
    const btn = screen.getByRole('button', { name: 'Resend code' });
    expect(btn).toBeEnabled();
    fireEvent.click(btn);
    expect(onResend).toHaveBeenCalledTimes(1);
  });

  it('shows a disabled "Sending..." button while a request is in flight', () => {
    render(<ResendPrompt onResend={vi.fn()} inFlight={true} />);
    expect(screen.getByRole('button', { name: /sending/i })).toBeDisabled();
    expect(screen.queryByRole('button', { name: 'Resend code' })).not.toBeInTheDocument();
  });

  it('shows the lockout message in seconds under a minute', () => {
    render(<ResendPrompt onResend={vi.fn()} locked={true} lockoutRemaining={45} />);
    expect(screen.getByText(/Too many resend attempts.*about 45 seconds/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /resend|sending/i })).not.toBeInTheDocument();
  });

  it('rounds the lockout up to whole minutes at and above 60 seconds', () => {
    const { rerender } = render(
      <ResendPrompt onResend={vi.fn()} locked={true} lockoutRemaining={60} />,
    );
    expect(screen.getByText(/about 1 minute\./i)).toBeInTheDocument();
    rerender(<ResendPrompt onResend={vi.fn()} locked={true} lockoutRemaining={61} />);
    expect(screen.getByText(/about 2 minutes\./i)).toBeInTheDocument();
  });

  it('reports a lockout ahead of an in-flight request when both are set', () => {
    render(
      <ResendPrompt onResend={vi.fn()} inFlight={true} locked={true} lockoutRemaining={30} />,
    );
    expect(screen.getByText(/Too many resend attempts/i)).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /sending/i })).not.toBeInTheDocument();
  });

  it('wraps the prompt in the live region the auth stylesheet targets', () => {
    const { container } = render(<ResendPrompt onResend={vi.fn()} />);
    const p = container.querySelector('p');
    expect(p).toHaveClass('auth__alt', 'auth__resend');
    expect(p).toHaveAttribute('aria-live', 'polite');
  });
});

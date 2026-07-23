import { render, screen } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import ForgotPassword from './index';
import AuthContext from '../contexts/AuthContext';

const withAuth = (ui) => (
  <AuthContext.Provider value={{ control_domain: 'example.com' }}>
    {ui}
  </AuthContext.Provider>
);

describe('ForgotPassword', () => {
  const defaultProps = {
    onSubmit: vi.fn(),
    onUsernameChange: vi.fn(),
    onBackToSignIn: vi.fn(),
    onProceed: vi.fn(),
    username: '',
    submitted: false,
  };

  it('renders the form view with a username field and Send button', () => {
    render(withAuth(<ForgotPassword {...defaultProps} />));
    expect(screen.getByLabelText('Username')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Send reset code' })).toBeInTheDocument();
  });

  it('renders the success view when submitted', () => {
    render(withAuth(<ForgotPassword {...defaultProps} submitted username="alice" />));
    // Without CodeDeliveryDetails the copy hedges across both channels.
    expect(screen.getByText('Check your email or phone')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Enter reset code' })).toBeInTheDocument();
  });

  it('names the channel the reset code actually went to', () => {
    const { rerender } = render(withAuth(
      <ForgotPassword {...defaultProps} submitted username="alice" deliveryMedium="email" />
    ));
    expect(screen.getByText('Check your email')).toBeInTheDocument();
    rerender(withAuth(
      <ForgotPassword {...defaultProps} submitted username="alice" deliveryMedium="phone" />
    ));
    expect(screen.getByText('Check your phone')).toBeInTheDocument();
  });
});

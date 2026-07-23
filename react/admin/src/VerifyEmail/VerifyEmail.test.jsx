import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import VerifyEmail from './index';
import AuthContext from '../contexts/AuthContext';

const withAuth = (ui) => (
  <AuthContext.Provider value={{ control_domain: 'example.com' }}>
    {ui}
  </AuthContext.Provider>
);

describe('VerifyEmail', () => {
  const defaultProps = {
    email: '',
    onEmailChange: vi.fn(),
    onSaveEmail: vi.fn(e => e.preventDefault()),
    onSubmit: vi.fn(e => e.preventDefault()),
    onCodeChange: vi.fn(),
    code: '',
    onSendCode: vi.fn(),
    onChangeEmail: vi.fn(),
    onSkip: vi.fn(e => e.preventDefault()),
  };

  describe('add mode', () => {
    it('prompts for a recovery address', () => {
      render(withAuth(<VerifyEmail {...defaultProps} mode="add" />));
      expect(screen.getByLabelText('Email address')).toBeInTheDocument();
      expect(
        screen.getByRole('button', { name: 'Send verification code' })
      ).toBeInTheDocument();
    });

    it('is skippable so legacy SMS-only users keep working', () => {
      const onSkip = vi.fn(e => e.preventDefault());
      render(withAuth(<VerifyEmail {...defaultProps} mode="add" onSkip={onSkip} />));
      fireEvent.click(screen.getAllByText('Skip for now')[0]);
      expect(onSkip).toHaveBeenCalledTimes(1);
    });

    it('submits the address via onSaveEmail', () => {
      const onSaveEmail = vi.fn(e => e.preventDefault());
      render(withAuth(
        <VerifyEmail {...defaultProps} mode="add" email="a@b.co" onSaveEmail={onSaveEmail} />
      ));
      fireEvent.click(screen.getByRole('button', { name: 'Send verification code' }));
      expect(onSaveEmail).toHaveBeenCalledTimes(1);
    });
  });

  describe('verify mode', () => {
    it('shows the address being verified and a code field', () => {
      render(withAuth(
        <VerifyEmail {...defaultProps} mode="verify" address="a@b.co" />
      ));
      expect(screen.getByText('a@b.co')).toBeInTheDocument();
      expect(screen.getByLabelText('Verification code')).toBeInTheDocument();
    });

    it('requests a fresh code via onSendCode', () => {
      const onSendCode = vi.fn();
      render(withAuth(
        <VerifyEmail {...defaultProps} mode="verify" address="a@b.co" onSendCode={onSendCode} />
      ));
      fireEvent.click(screen.getByRole('button', { name: 'Send a new code' }));
      expect(onSendCode).toHaveBeenCalledTimes(1);
    });

    it('submits the code via onSubmit', () => {
      const onSubmit = vi.fn(e => e.preventDefault());
      render(withAuth(
        <VerifyEmail {...defaultProps} mode="verify" address="a@b.co" code="123456" onSubmit={onSubmit} />
      ));
      fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
      expect(onSubmit).toHaveBeenCalledTimes(1);
    });

    it('offers switching to a different address', () => {
      const onChangeEmail = vi.fn(e => e.preventDefault());
      render(withAuth(
        <VerifyEmail {...defaultProps} mode="verify" address="a@b.co" onChangeEmail={onChangeEmail} />
      ));
      fireEvent.click(screen.getByText('Use a different email'));
      expect(onChangeEmail).toHaveBeenCalledTimes(1);
    });
  });
});

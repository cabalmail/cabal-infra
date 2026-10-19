import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import RecoveryEmail from './RecoveryEmail';
import { CognitoError } from '../auth';

// recoveryApi double: load answers with `current`, the rest resolve unless
// a test overrides them.
function apiWith(current = { address: null, verified: false }) {
  return {
    load: vi.fn(() => Promise.resolve(current)),
    save: vi.fn(() => Promise.resolve()),
    resend: vi.fn(() => Promise.resolve()),
    verify: vi.fn(() => Promise.resolve()),
  };
}

function renderWith(api, { smsEnabled = true, setMessage = vi.fn() } = {}) {
  render(<RecoveryEmail recoveryApi={api} smsEnabled={smsEnabled} setMessage={setMessage} />);
  return setMessage;
}

const typeAddress = (value) => fireEvent.change(screen.getByLabelText(/email address|new recovery email/i), { target: { value } });
const typeCode = (value) => fireEvent.change(screen.getByLabelText('Verification code'), { target: { value } });

describe('RecoveryEmail', () => {
  // The phone-only account docs/auth.md allows when SMS is on: the
  // post-sign-in gate no longer asks it, so this is where it adds one.
  it('adds and verifies an address for an account with none', async () => {
    const api = apiWith();
    const setMessage = renderWith(api);
    expect(await screen.findByText(/Your phone number recovers your account/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Add recovery email' }));

    const save = screen.getByRole('button', { name: 'Save and send code' });
    typeAddress('not-an-address');
    expect(save).toBeDisabled();
    typeAddress('alice@example.net');
    fireEvent.click(save);

    await screen.findByText('alice@example.net');
    expect(api.save).toHaveBeenCalledWith('alice@example.net');
    expect(setMessage).toHaveBeenLastCalledWith('A verification code has been sent to alice@example.net.', false);

    typeCode('424242');
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
    await screen.findByText('is verified and can be used to recover your account.');
    expect(api.verify).toHaveBeenCalledWith('424242');
    expect(setMessage).toHaveBeenLastCalledWith('Email verified. It can now be used for account recovery.', false);
  });

  it('asks for an address with the password wording when SMS is off', async () => {
    renderWith(apiWith(), { smsEnabled: false });
    expect(await screen.findByText(/so you can get back in if you forget your password/)).toBeInTheDocument();
  });

  it('shows a verified address with only a change action', async () => {
    renderWith(apiWith({ address: 'alice@example.net', verified: true }));
    await screen.findByText('is verified and can be used to recover your account.');
    expect(screen.getByRole('button', { name: 'Change address' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Verify address' })).toBeNull();
  });

  it('sends a code for an unverified address before asking for it', async () => {
    const api = apiWith({ address: 'alice@example.net', verified: false });
    renderWith(api);
    fireEvent.click(await screen.findByRole('button', { name: 'Verify address' }));
    await screen.findByLabelText('Verification code');
    expect(api.resend).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: 'Send a new code' }));
    await waitFor(() => expect(api.resend).toHaveBeenCalledTimes(2));
  });

  it('warns that changing a verified address suspends it until the new one is verified', async () => {
    renderWith(apiWith({ address: 'alice@example.net', verified: true }));
    fireEvent.click(await screen.findByRole('button', { name: 'Change address' }));
    expect(screen.getByLabelText('New recovery email')).toBeInTheDocument();
    expect(screen.getByText(/Until you verify it, alice@example.net stops being used for recovery/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    await screen.findByText('is verified and can be used to recover your account.');
  });

  it('keeps the code form open after a wrong code', async () => {
    const api = apiWith({ address: 'alice@example.net', verified: false });
    api.verify = vi.fn(() => Promise.reject(new CognitoError('CodeMismatchException', 'Invalid code')));
    const setMessage = renderWith(api);
    fireEvent.click(await screen.findByRole('button', { name: 'Verify address' }));
    await screen.findByLabelText('Verification code');
    typeCode('000000');
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
    await waitFor(() => expect(setMessage).toHaveBeenLastCalledWith(
      'That code did not match. Check the email and try again.', true
    ));
    expect(screen.getByLabelText('Verification code')).toBeInTheDocument();
  });

  it('says to wait when Cognito limits code sends', async () => {
    const api = apiWith();
    api.save = vi.fn(() => Promise.reject(new CognitoError('LimitExceededException', 'Attempt limit exceeded')));
    const setMessage = renderWith(api);
    fireEvent.click(await screen.findByRole('button', { name: 'Add recovery email' }));
    typeAddress('alice@example.net');
    fireEvent.click(screen.getByRole('button', { name: 'Save and send code' }));
    await waitFor(() => expect(setMessage).toHaveBeenLastCalledWith('Too many attempts. Please try again later.', true));
    expect(screen.getByLabelText('Email address')).toBeInTheDocument();
  });

  it('offers a retry when the address cannot be read', async () => {
    const api = apiWith({ address: 'alice@example.net', verified: true });
    api.load = vi.fn()
      .mockImplementationOnce(() => Promise.reject(new Error('offline')))
      .mockImplementation(() => Promise.resolve({ address: 'alice@example.net', verified: true }));
    renderWith(api);
    fireEvent.click(await screen.findByRole('button', { name: 'Retry' }));
    await screen.findByText('is verified and can be used to recover your account.');
  });
});

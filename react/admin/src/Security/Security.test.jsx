import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import Security from './index';

// mfaApi factory: getStatus resolves synchronously with `enabled`;
// beginEnroll hands back a fixed secret; confirmEnroll/disable succeed.
function apiWith({ enabled = false } = {}) {
  return {
    getStatus: vi.fn((cb) => cb(null, enabled)),
    beginEnroll: vi.fn((callbacks) => callbacks.associateSecretCode('SECRETKEY234567')),
    confirmEnroll: vi.fn((code, callbacks) => callbacks.onSuccess()),
    disable: vi.fn((cb) => cb(null)),
  };
}

describe('Security', () => {
  it('shows the off state with an enroll action', async () => {
    render(<Security userName="alice" mfaApi={apiWith()} setMessage={vi.fn()} />);
    await waitFor(() => {
      expect(
        screen.getByRole('button', { name: 'Set up authenticator app' })
      ).toBeInTheDocument();
    });
  });

  it('shows the on state with a disable action', async () => {
    render(
      <Security userName="alice" mfaApi={apiWith({ enabled: true })} setMessage={vi.fn()} />
    );
    await waitFor(() => {
      expect(
        screen.getByRole('button', { name: 'Turn off two-factor authentication' })
      ).toBeInTheDocument();
    });
  });

  it('walks through enrollment: secret, QR, code, confirm', async () => {
    const api = apiWith();
    const setMessage = vi.fn();
    render(<Security userName="alice" mfaApi={api} setMessage={setMessage} />);
    fireEvent.click(
      await screen.findByRole('button', { name: 'Set up authenticator app' })
    );
    // Manual key and QR appear
    expect(screen.getByText('SECRETKEY234567')).toBeInTheDocument();
    expect(screen.getByLabelText('TOTP enrollment QR code')).toBeInTheDocument();
    // Enter and confirm the code
    fireEvent.change(screen.getByLabelText('Code from your app'), {
      target: { value: '123456' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Confirm' }));
    expect(api.confirmEnroll).toHaveBeenCalledWith('123456', expect.any(Object));
    // Lands in the on state
    await waitFor(() => {
      expect(
        screen.getByRole('button', { name: 'Turn off two-factor authentication' })
      ).toBeInTheDocument();
    });
    expect(setMessage).toHaveBeenCalledWith(expect.stringMatching(/is on/), false);
  });

  it('cancel during enrollment returns to the off state', async () => {
    render(<Security userName="alice" mfaApi={apiWith()} setMessage={vi.fn()} />);
    fireEvent.click(
      await screen.findByRole('button', { name: 'Set up authenticator app' })
    );
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(
      screen.getByRole('button', { name: 'Set up authenticator app' })
    ).toBeInTheDocument();
  });

  it('disable turns two-factor off', async () => {
    const api = apiWith({ enabled: true });
    render(<Security userName="alice" mfaApi={api} setMessage={vi.fn()} />);
    fireEvent.click(
      await screen.findByRole('button', { name: 'Turn off two-factor authentication' })
    );
    expect(api.disable).toHaveBeenCalledTimes(1);
    await waitFor(() => {
      expect(
        screen.getByRole('button', { name: 'Set up authenticator app' })
      ).toBeInTheDocument();
    });
  });

  it('offers retry when the status read fails', async () => {
    const api = apiWith();
    api.getStatus = vi.fn((cb) => cb(new Error('boom')));
    render(<Security userName="alice" mfaApi={api} setMessage={vi.fn()} />);
    await waitFor(() => {
      expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument();
    });
  });
});

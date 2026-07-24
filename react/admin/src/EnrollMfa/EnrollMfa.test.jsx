import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import EnrollMfa from './index';
import AuthContext from '../contexts/AuthContext';

const withAuth = (ui) => (
  <AuthContext.Provider value={{ control_domain: 'example.com' }}>
    {ui}
  </AuthContext.Provider>
);

describe('EnrollMfa', () => {
  it('offers enrollment as the primary action', () => {
    const onSetUp = vi.fn();
    render(withAuth(<EnrollMfa onSetUp={onSetUp} onLater={vi.fn()} />));
    fireEvent.click(
      screen.getByRole('button', { name: 'Set up two-factor authentication' })
    );
    expect(onSetUp).toHaveBeenCalledTimes(1);
  });

  it('is skippable via Remind me later', () => {
    const onLater = vi.fn(e => e.preventDefault());
    render(withAuth(<EnrollMfa onSetUp={vi.fn()} onLater={onLater} />));
    fireEvent.click(screen.getByText('Remind me later'));
    expect(onLater).toHaveBeenCalledTimes(1);
  });
});

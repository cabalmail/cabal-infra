/* Phase 8 — responsive viewport tests for the Nav sidebar toggle. */

import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import Nav from './index';
import { setViewport, PHONE, TABLET, DESKTOP } from '../test/viewport';

const ACCENTS = ['ink', 'oxblood', 'forest', 'azure', 'amber', 'plum'];

const baseProps = {
  loggedIn: true,
  onClick: vi.fn(),
  view: 'Email',
  doLogout: vi.fn(),
  isAdmin: false,
  userName: 'alex',
  accent: 'forest',
  onSelectAccent: vi.fn(),
  accents: ACCENTS,
};

describe('Nav sidebar toggle (viewport)', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('renders the sidebar toggle on phone viewport in Email view', () => {
    setViewport(...PHONE);
    render(<Nav {...baseProps} />);
    expect(screen.getByRole('button', { name: 'Open sidebar' })).toBeInTheDocument();
  });

  it('renders the sidebar toggle on tablet viewport in Email view', () => {
    setViewport(...TABLET);
    render(<Nav {...baseProps} />);
    expect(screen.getByRole('button', { name: 'Open sidebar' })).toBeInTheDocument();
  });

  it('still renders the sidebar toggle in the DOM on desktop (CSS hides it)', () => {
    // Desktop relies on CSS to hide the toggle; jsdom does not resolve
    // media queries through stylesheets, so we only assert that the button
    // is present in the DOM and leave the visibility check to CSS.
    setViewport(...DESKTOP);
    render(<Nav {...baseProps} />);
    expect(screen.getByRole('button', { name: 'Open sidebar' })).toBeInTheDocument();
  });

  it('dispatches cabal:toggle-nav-drawer when sidebar toggle is clicked', () => {
    setViewport(...PHONE);
    const listener = vi.fn();
    window.addEventListener('cabal:toggle-nav-drawer', listener);
    render(<Nav {...baseProps} />);
    fireEvent.click(screen.getByRole('button', { name: 'Open sidebar' }));
    expect(listener).toHaveBeenCalledTimes(1);
    window.removeEventListener('cabal:toggle-nav-drawer', listener);
  });

  it('does not render the sidebar toggle when logged out', () => {
    setViewport(...PHONE);
    render(<Nav {...baseProps} loggedIn={false} />);
    expect(screen.queryByRole('button', { name: 'Open sidebar' })).not.toBeInTheDocument();
  });

  it('renders the sidebar toggle button even in non-Email views (hidden via CSS)', () => {
    // The button is always in the DOM when logged in, but the view prop determines
    // whether it's visually hidden via the nav__sidebar-toggle--hidden class.
    setViewport(...PHONE);
    render(<Nav {...baseProps} view="Users" />);
    const button = screen.getByRole('button', { name: 'Open sidebar' });
    expect(button).toBeInTheDocument();
    expect(button).toHaveClass('nav__sidebar-toggle--hidden');
  });
});

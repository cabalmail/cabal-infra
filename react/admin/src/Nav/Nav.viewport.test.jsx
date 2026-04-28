/* Phase 8 — responsive viewport tests for the Nav hamburger. */

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

describe('Nav hamburger (viewport)', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('renders the hamburger button on phone viewport', () => {
    setViewport(...PHONE);
    render(<Nav {...baseProps} />);
    expect(screen.getByRole('button', { name: 'Open navigation' })).toBeInTheDocument();
  });

  it('renders the hamburger button on tablet viewport', () => {
    setViewport(...TABLET);
    render(<Nav {...baseProps} />);
    expect(screen.getByRole('button', { name: 'Open navigation' })).toBeInTheDocument();
  });

  it('still renders the hamburger in the DOM on desktop (CSS hides it)', () => {
    // Desktop relies on CSS to hide the hamburger; jsdom does not resolve
    // media queries through stylesheets, so we only assert that the button
    // is present in the DOM and leave the visibility check to CSS.
    setViewport(...DESKTOP);
    render(<Nav {...baseProps} />);
    expect(screen.getByRole('button', { name: 'Open navigation' })).toBeInTheDocument();
  });

  it('dispatches cabal:toggle-nav-drawer when hamburger is clicked', () => {
    setViewport(...PHONE);
    const listener = vi.fn();
    window.addEventListener('cabal:toggle-nav-drawer', listener);
    render(<Nav {...baseProps} />);
    fireEvent.click(screen.getByRole('button', { name: 'Open navigation' }));
    expect(listener).toHaveBeenCalledTimes(1);
    window.removeEventListener('cabal:toggle-nav-drawer', listener);
  });

  it('does not render the hamburger when logged out', () => {
    setViewport(...PHONE);
    render(<Nav {...baseProps} loggedIn={false} />);
    expect(screen.queryByRole('button', { name: 'Open navigation' })).not.toBeInTheDocument();
  });
});

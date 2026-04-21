import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import Nav from './index';

const ACCENTS = ['ink', 'oxblood', 'forest', 'azure', 'amber', 'plum'];

const baseProps = {
  loggedIn: false,
  onClick: vi.fn(),
  view: 'Login',
  doLogout: vi.fn(),
  isAdmin: false,
  userName: null,
  accent: 'forest',
  onSelectAccent: vi.fn(),
  accents: ACCENTS,
};

describe('Nav', () => {
  it('renders the Cabalmail wordmark', () => {
    render(<Nav {...baseProps} />);
    expect(screen.getByText('Cabalmail')).toBeInTheDocument();
  });

  it('renders Log in and Sign up buttons when logged out', () => {
    render(<Nav {...baseProps} loggedIn={false} />);
    expect(screen.getByRole('button', { name: 'Log in' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Sign up' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Account menu' })).not.toBeInTheDocument();
  });

  it('hides the search input when logged out', () => {
    render(<Nav {...baseProps} loggedIn={false} />);
    expect(screen.queryByRole('searchbox')).not.toBeInTheDocument();
  });

  it('renders the search input and avatar when logged in', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" />);
    expect(screen.getByRole('searchbox')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Account menu' })).toBeInTheDocument();
  });

  it('does not render a manual theme toggle', () => {
    render(<Nav {...baseProps} />);
    expect(screen.queryByRole('button', { name: /switch to (light|dark) theme/i })).not.toBeInTheDocument();
  });

  it('opens the account menu when the avatar is clicked', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" />);
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    expect(screen.getByRole('menu')).toBeInTheDocument();
  });

  it('shows the user view switcher items in the menu', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    expect(screen.getByRole('menuitem', { name: 'Email' })).toBeInTheDocument();
    expect(screen.getByRole('menuitem', { name: 'Folders' })).toBeInTheDocument();
    expect(screen.getByRole('menuitem', { name: 'Addresses' })).toBeInTheDocument();
    expect(screen.getByRole('menuitem', { name: 'Log out' })).toBeInTheDocument();
  });

  it('hides admin-only items when isAdmin is false', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" isAdmin={false} />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    expect(screen.queryByRole('menuitem', { name: 'Users' })).not.toBeInTheDocument();
    expect(screen.queryByRole('menuitem', { name: 'DMARC' })).not.toBeInTheDocument();
  });

  it('shows admin-only items when isAdmin is true', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" isAdmin={true} />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    expect(screen.getByRole('menuitem', { name: 'Users' })).toBeInTheDocument();
    expect(screen.getByRole('menuitem', { name: 'DMARC' })).toBeInTheDocument();
  });

  it('marks the active view in the menu', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" view="Email" />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    expect(screen.getByRole('menuitem', { name: 'Email' })).toHaveClass('is-active');
    expect(screen.getByRole('menuitem', { name: 'Folders' })).not.toHaveClass('is-active');
  });

  it('calls onClick with the event when a menu item is chosen', () => {
    const onClick = vi.fn();
    render(<Nav {...baseProps} loggedIn={true} userName="alex" onClick={onClick} />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Addresses' }));
    expect(onClick).toHaveBeenCalledTimes(1);
    expect(onClick.mock.calls[0][0].target.name).toBe('Addresses');
  });

  it('calls doLogout when the log out item is clicked', () => {
    const doLogout = vi.fn();
    render(<Nav {...baseProps} loggedIn={true} userName="alex" doLogout={doLogout} />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    fireEvent.click(screen.getByRole('menuitem', { name: 'Log out' }));
    expect(doLogout).toHaveBeenCalledTimes(1);
  });

  it('calls onSelectAccent when an accent swatch is clicked', () => {
    const onSelectAccent = vi.fn();
    render(<Nav {...baseProps} loggedIn={true} userName="alex" onSelectAccent={onSelectAccent} />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    fireEvent.click(screen.getByRole('button', { name: 'Accent azure' }));
    expect(onSelectAccent).toHaveBeenCalledWith('azure');
  });

  it('applies logged-in class when logged in', () => {
    const { container } = render(<Nav {...baseProps} loggedIn={true} userName="alex" />);
    expect(container.firstChild).toHaveClass('logged-in');
  });

  it('applies logged-out class when logged out', () => {
    const { container } = render(<Nav {...baseProps} loggedIn={false} />);
    expect(container.firstChild).toHaveClass('logged-out');
  });
});

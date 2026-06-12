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
    expect(screen.getByRole('menuitem', { name: 'Log out' })).toBeInTheDocument();
  });

  it('hides the Folders menu item for everyone', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" isAdmin={true} />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    expect(screen.queryByRole('menuitem', { name: 'Folders' })).not.toBeInTheDocument();
  });

  it('hides admin-only items when isAdmin is false', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" isAdmin={false} />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    expect(screen.queryByRole('menuitem', { name: 'Addresses' })).not.toBeInTheDocument();
    expect(screen.queryByRole('menuitem', { name: 'Users' })).not.toBeInTheDocument();
    expect(screen.queryByRole('menuitem', { name: 'DMARC' })).not.toBeInTheDocument();
  });

  it('shows admin-only items when isAdmin is true', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" isAdmin={true} />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    expect(screen.getByRole('menuitem', { name: 'Addresses' })).toBeInTheDocument();
    expect(screen.getByRole('menuitem', { name: 'Users' })).toBeInTheDocument();
    expect(screen.getByRole('menuitem', { name: 'DMARC' })).toBeInTheDocument();
  });

  it('marks the active view in the menu', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" view="Email" isAdmin={true} />);
    fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
    expect(screen.getByRole('menuitem', { name: 'Email' })).toHaveClass('is-active');
    expect(screen.getByRole('menuitem', { name: 'Addresses' })).not.toHaveClass('is-active');
  });

  it('calls onClick with the event when a menu item is chosen', () => {
    const onClick = vi.fn();
    render(<Nav {...baseProps} loggedIn={true} userName="alex" isAdmin={true} onClick={onClick} />);
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

  describe('display name field', () => {
    it('renders the current display name in the menu', () => {
      render(
        <Nav
          {...baseProps}
          loggedIn={true}
          userName="alex"
          displayName="Alex Example"
          onChangeDisplayName={vi.fn()}
        />,
      );
      fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
      const input = screen.getByRole('textbox', { name: 'Display name for outgoing mail' });
      expect(input.value).toBe('Alex Example');
    });

    it('calls onChangeDisplayName as the user types', () => {
      const onChangeDisplayName = vi.fn();
      render(
        <Nav
          {...baseProps}
          loggedIn={true}
          userName="alex"
          displayName=""
          onChangeDisplayName={onChangeDisplayName}
        />,
      );
      fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
      const input = screen.getByRole('textbox', { name: 'Display name for outgoing mail' });
      fireEvent.change(input, { target: { value: 'Alex' } });
      expect(onChangeDisplayName).toHaveBeenCalledWith('Alex');
    });

    it('hides the field when no onChangeDisplayName handler is supplied', () => {
      render(<Nav {...baseProps} loggedIn={true} userName="alex" />);
      fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
      expect(
        screen.queryByRole('textbox', { name: 'Display name for outgoing mail' }),
      ).not.toBeInTheDocument();
    });
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

  it('reflects the committed searchQuery in the input', () => {
    render(<Nav {...baseProps} loggedIn={true} userName="alex" searchQuery="invoices" />);
    expect(screen.getByRole('searchbox').value).toBe('invoices');
  });

  it('commits the typed value to onSearchSubmit when Enter is pressed', () => {
    const onSearchSubmit = vi.fn();
    render(<Nav {...baseProps} loggedIn={true} userName="alex" onSearchSubmit={onSearchSubmit} />);
    const input = screen.getByRole('searchbox');
    fireEvent.change(input, { target: { value: 'hello world' } });
    fireEvent.submit(input.closest('form'));
    expect(onSearchSubmit).toHaveBeenCalledWith('hello world');
  });

  it('Escape clears a non-empty search and commits "" to onSearchSubmit', () => {
    const onSearchSubmit = vi.fn();
    render(
      <Nav
        {...baseProps}
        loggedIn={true}
        userName="alex"
        searchQuery="prior"
        onSearchSubmit={onSearchSubmit}
      />,
    );
    const input = screen.getByRole('searchbox');
    fireEvent.keyDown(input, { key: 'Escape' });
    expect(onSearchSubmit).toHaveBeenCalledWith('');
    expect(input.value).toBe('');
  });

  describe('monitoring entries', () => {
    const adminMonitoringProps = {
      ...baseProps,
      loggedIn: true,
      userName: 'alex',
      isAdmin: true,
      monitoring: true,
      controlDomain: 'cabalmail.com',
    };

    it('renders Uptime/Healthchecks/Grafana as external links when admin + monitoring', () => {
      render(<Nav {...adminMonitoringProps} />);
      fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
      const kuma = screen.getByRole('menuitem', { name: /Uptime Kuma/ });
      const hc = screen.getByRole('menuitem', { name: /Healthchecks/ });
      const grafana = screen.getByRole('menuitem', { name: /Grafana/ });
      expect(kuma).toHaveAttribute('href', 'https://uptime.cabalmail.com/');
      expect(kuma).toHaveAttribute('target', '_blank');
      expect(kuma).toHaveAttribute('rel', expect.stringContaining('noopener'));
      expect(hc).toHaveAttribute('href', 'https://heartbeat.cabalmail.com/');
      expect(grafana).toHaveAttribute('href', 'https://metrics.cabalmail.com/');
    });

    it('hides monitoring entries when monitoring is disabled', () => {
      render(<Nav {...adminMonitoringProps} monitoring={false} />);
      fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
      expect(screen.queryByRole('menuitem', { name: /Uptime Kuma/ })).not.toBeInTheDocument();
      expect(screen.queryByRole('menuitem', { name: /Healthchecks/ })).not.toBeInTheDocument();
      expect(screen.queryByRole('menuitem', { name: /Grafana/ })).not.toBeInTheDocument();
    });

    it('hides monitoring entries from non-admin users even when monitoring is enabled', () => {
      render(<Nav {...adminMonitoringProps} isAdmin={false} />);
      fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
      expect(screen.queryByRole('menuitem', { name: /Uptime Kuma/ })).not.toBeInTheDocument();
    });

    it('hides monitoring entries until controlDomain is known', () => {
      render(<Nav {...adminMonitoringProps} controlDomain={null} />);
      fireEvent.click(screen.getByRole('button', { name: 'Account menu' }));
      expect(screen.queryByRole('menuitem', { name: /Uptime Kuma/ })).not.toBeInTheDocument();
    });
  });
});

import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import Nav from './index';

describe('Nav', () => {
  const defaultProps = {
    loggedIn: false,
    onClick: vi.fn(),
    view: 'Login',
    doLogout: vi.fn()
  };

  it('renders all nav items', () => {
    render(<Nav {...defaultProps} />);
    expect(screen.getByText('Email')).toBeInTheDocument();
    expect(screen.getByText('Folders')).toBeInTheDocument();
    expect(screen.getByText('Addresses')).toBeInTheDocument();
    expect(screen.getByText('Users')).toBeInTheDocument();
    expect(screen.getByText('DMARC')).toBeInTheDocument();
    expect(screen.getByText('Log in')).toBeInTheDocument();
    expect(screen.getByText('Sign up')).toBeInTheDocument();
    expect(screen.getByText('Log out')).toBeInTheDocument();
  });

  it('renders nav items as buttons, not anchors', () => {
    render(<Nav {...defaultProps} />);
    const buttons = screen.getAllByRole('button');
    expect(buttons.length).toBe(8);
  });

  it('marks the active view', () => {
    render(<Nav {...defaultProps} view="Email" />);
    expect(screen.getByText('Email')).toHaveClass('active');
    expect(screen.getByText('Folders')).not.toHaveClass('active');
  });

  it('applies logged-in class when logged in', () => {
    const { container } = render(<Nav {...defaultProps} loggedIn={true} />);
    expect(container.firstChild).toHaveClass('logged-in');
  });

  it('applies logged-out class when logged out', () => {
    const { container } = render(<Nav {...defaultProps} loggedIn={false} />);
    expect(container.firstChild).toHaveClass('logged-out');
  });

  it('calls onClick when a nav item is clicked', () => {
    const onClick = vi.fn();
    render(<Nav {...defaultProps} onClick={onClick} />);
    fireEvent.click(screen.getByText('Email'));
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('calls doLogout when log out is clicked', () => {
    const doLogout = vi.fn();
    render(<Nav {...defaultProps} doLogout={doLogout} />);
    fireEvent.click(screen.getByText('Log out'));
    expect(doLogout).toHaveBeenCalledTimes(1);
  });
});

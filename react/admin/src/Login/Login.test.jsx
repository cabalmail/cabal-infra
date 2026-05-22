import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import Login from './index';
import AuthContext from '../contexts/AuthContext';

const withAuth = (ui) => (
  <AuthContext.Provider value={{ control_domain: 'example.com' }}>
    {ui}
  </AuthContext.Provider>
);

describe('Login', () => {
  const defaultProps = {
    onSubmit: vi.fn(),
    onUsernameChange: vi.fn(),
    onPasswordChange: vi.fn(),
    username: '',
    password: ''
  };

  it('renders username and password fields', () => {
    render(withAuth(<Login {...defaultProps} />));
    expect(screen.getByLabelText('Username')).toBeInTheDocument();
    expect(screen.getByLabelText('Password')).toBeInTheDocument();
  });

  it('renders a submit button', () => {
    render(withAuth(<Login {...defaultProps} />));
    expect(screen.getByRole('button', { name: 'Sign in' })).toBeInTheDocument();
  });

  it('displays the provided username value', () => {
    render(withAuth(<Login {...defaultProps} username="alice" />));
    expect(screen.getByLabelText('Username')).toHaveValue('alice');
  });

  it('calls onUsernameChange when username input changes', () => {
    const onUsernameChange = vi.fn();
    render(withAuth(<Login {...defaultProps} onUsernameChange={onUsernameChange} />));
    fireEvent.change(screen.getByLabelText('Username'), { target: { value: 'bob' } });
    expect(onUsernameChange).toHaveBeenCalledTimes(1);
  });

  it('calls onSubmit when form is submitted', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(withAuth(<Login {...defaultProps} onSubmit={onSubmit} />));
    fireEvent.submit(screen.getByRole('button', { name: 'Sign in' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it('toggles password visibility via Show/Hide button', () => {
    render(withAuth(<Login {...defaultProps} password="secret" />));
    const input = screen.getByLabelText('Password');
    expect(input).toHaveAttribute('type', 'password');
    fireEvent.click(screen.getByRole('button', { name: 'Show password' }));
    expect(input).toHaveAttribute('type', 'text');
  });
});

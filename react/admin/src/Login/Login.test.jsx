import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import Login from './index';

describe('Login', () => {
  const defaultProps = {
    onSubmit: vi.fn(),
    onUsernameChange: vi.fn(),
    onPasswordChange: vi.fn(),
    username: '',
    password: ''
  };

  it('renders username and password fields', () => {
    render(<Login {...defaultProps} />);
    expect(screen.getByLabelText('Username')).toBeInTheDocument();
    expect(screen.getByLabelText('Password')).toBeInTheDocument();
  });

  it('renders a submit button', () => {
    render(<Login {...defaultProps} />);
    expect(screen.getByRole('button', { name: 'Sign in' })).toBeInTheDocument();
  });

  it('displays the provided username value', () => {
    render(<Login {...defaultProps} username="alice" />);
    expect(screen.getByLabelText('Username')).toHaveValue('alice');
  });

  it('calls onUsernameChange when username input changes', () => {
    const onUsernameChange = vi.fn();
    render(<Login {...defaultProps} onUsernameChange={onUsernameChange} />);
    fireEvent.change(screen.getByLabelText('Username'), { target: { value: 'bob' } });
    expect(onUsernameChange).toHaveBeenCalledTimes(1);
  });

  it('calls onSubmit when form is submitted', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(<Login {...defaultProps} onSubmit={onSubmit} />);
    fireEvent.submit(screen.getByRole('button', { name: 'Sign in' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });

  it('toggles password visibility via Show/Hide button', () => {
    render(<Login {...defaultProps} password="secret" />);
    const input = screen.getByLabelText('Password');
    expect(input).toHaveAttribute('type', 'password');
    fireEvent.click(screen.getByRole('button', { name: 'Show password' }));
    expect(input).toHaveAttribute('type', 'text');
  });
});

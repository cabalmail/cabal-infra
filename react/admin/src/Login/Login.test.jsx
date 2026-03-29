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
    expect(screen.getByLabelText('User Name')).toBeInTheDocument();
    expect(screen.getByLabelText('Password')).toBeInTheDocument();
  });

  it('renders a submit button', () => {
    render(<Login {...defaultProps} />);
    expect(screen.getByRole('button', { name: 'Login' })).toBeInTheDocument();
  });

  it('displays the provided username value', () => {
    render(<Login {...defaultProps} username="alice" />);
    expect(screen.getByLabelText('User Name')).toHaveValue('alice');
  });

  it('calls onUsernameChange when username input changes', () => {
    const onUsernameChange = vi.fn();
    render(<Login {...defaultProps} onUsernameChange={onUsernameChange} />);
    fireEvent.change(screen.getByLabelText('User Name'), { target: { value: 'bob' } });
    expect(onUsernameChange).toHaveBeenCalledTimes(1);
  });

  it('calls onSubmit when form is submitted', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(<Login {...defaultProps} onSubmit={onSubmit} />);
    fireEvent.submit(screen.getByRole('button', { name: 'Login' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });
});

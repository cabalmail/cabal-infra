import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import SignUp from './index';

describe('SignUp', () => {
  const defaultProps = {
    onSubmit: vi.fn(),
    onUsernameChange: vi.fn(),
    onPasswordChange: vi.fn(),
    onPhoneChange: vi.fn(),
    username: '',
    password: '',
    phone: ''
  };

  it('renders username, phone, and password fields', () => {
    render(<SignUp {...defaultProps} />);
    expect(screen.getByLabelText('User Name')).toBeInTheDocument();
    expect(screen.getByLabelText('Phone')).toBeInTheDocument();
    expect(screen.getByLabelText('Password')).toBeInTheDocument();
  });

  it('renders a submit button', () => {
    render(<SignUp {...defaultProps} />);
    expect(screen.getByRole('button', { name: 'Signup' })).toBeInTheDocument();
  });

  it('shows phone placeholder', () => {
    render(<SignUp {...defaultProps} />);
    expect(screen.getByPlaceholderText('+12125555555')).toBeInTheDocument();
  });

  it('calls onPhoneChange when phone input changes', () => {
    const onPhoneChange = vi.fn();
    render(<SignUp {...defaultProps} onPhoneChange={onPhoneChange} />);
    fireEvent.change(screen.getByLabelText('Phone'), { target: { value: '+1555' } });
    expect(onPhoneChange).toHaveBeenCalledTimes(1);
  });

  it('calls onSubmit when form is submitted', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(<SignUp {...defaultProps} onSubmit={onSubmit} />);
    fireEvent.submit(screen.getByRole('button', { name: 'Signup' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });
});

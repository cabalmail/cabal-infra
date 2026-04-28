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

  const validProps = {
    username: 'alice',
    phone: '+12125551234',
    password: 'correct-horse-battery-staple',
  };

  it('renders username, phone, and password fields', () => {
    render(<SignUp {...defaultProps} />);
    expect(screen.getByLabelText('Username')).toBeInTheDocument();
    expect(screen.getByLabelText('Phone number')).toBeInTheDocument();
    expect(screen.getByLabelText('Password')).toBeInTheDocument();
    expect(screen.getByLabelText('Confirm password')).toBeInTheDocument();
  });

  it('renders a submit button', () => {
    render(<SignUp {...defaultProps} />);
    expect(screen.getByRole('button', { name: 'Create account' })).toBeInTheDocument();
  });

  it('disables submit until all fields are valid', () => {
    render(<SignUp {...defaultProps} />);
    expect(screen.getByRole('button', { name: 'Create account' })).toBeDisabled();
  });

  it('calls onPhoneChange when phone input changes', () => {
    const onPhoneChange = vi.fn();
    render(<SignUp {...defaultProps} onPhoneChange={onPhoneChange} />);
    fireEvent.change(screen.getByLabelText('Phone number'), { target: { value: '+1555' } });
    expect(onPhoneChange).toHaveBeenCalledTimes(1);
  });

  it('calls onSubmit when the fully-valid form is submitted', () => {
    const onSubmit = vi.fn(e => e.preventDefault());
    render(<SignUp {...defaultProps} {...validProps} onSubmit={onSubmit} />);
    fireEvent.change(screen.getByLabelText('Confirm password'), {
      target: { value: validProps.password },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Create account' }));
    expect(onSubmit).toHaveBeenCalledTimes(1);
  });
});

import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import AppMessage from './index';

describe('AppMessage', () => {
  it('renders the message text', () => {
    render(<AppMessage message="Hello" hide={false} error={false} />);
    expect(screen.getByText('Hello')).toBeInTheDocument();
  });

  it('applies hidden class when hide is true', () => {
    render(<AppMessage message="Hidden" hide={true} error={false} />);
    const el = screen.getByText('Hidden');
    expect(el).toHaveClass('hidden');
    expect(el).not.toHaveClass('visible');
  });

  it('applies visible class when hide is false', () => {
    render(<AppMessage message="Visible" hide={false} error={false} />);
    expect(screen.getByText('Visible')).toHaveClass('visible');
  });

  it('applies error class when error is true', () => {
    render(<AppMessage message="Err" hide={false} error={true} />);
    expect(screen.getByText('Err')).toHaveClass('error');
  });

  it('applies info class when error is false', () => {
    render(<AppMessage message="Info" hide={false} error={false} />);
    expect(screen.getByText('Info')).toHaveClass('info');
  });
});

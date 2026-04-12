import { render, screen, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import ErrorBoundary from './ErrorBoundary';

function ThrowingChild() {
  throw new Error('Test error');
}

function GoodChild() {
  return <div>All good</div>;
}

describe('ErrorBoundary', () => {
  // Suppress console.error for expected errors in tests
  const originalError = console.error;
  beforeEach(() => { console.error = vi.fn(); });
  afterEach(() => { console.error = originalError; });

  it('renders children when no error', () => {
    render(
      <ErrorBoundary name="Test">
        <GoodChild />
      </ErrorBoundary>
    );
    expect(screen.getByText('All good')).toBeInTheDocument();
  });

  it('renders fallback UI when child throws', () => {
    render(
      <ErrorBoundary name="Email">
        <ThrowingChild />
      </ErrorBoundary>
    );
    expect(screen.getByText('Something went wrong')).toBeInTheDocument();
    expect(screen.getByText('The Email view encountered an error.')).toBeInTheDocument();
  });

  it('resets error state when Try Again is clicked', () => {
    let shouldThrow = true;
    function MaybeThrow() {
      if (shouldThrow) throw new Error('Test error');
      return <div>All good</div>;
    }
    render(
      <ErrorBoundary name="Test">
        <MaybeThrow />
      </ErrorBoundary>
    );
    expect(screen.getByText('Something went wrong')).toBeInTheDocument();
    shouldThrow = false;
    fireEvent.click(screen.getByText('Try Again'));
    expect(screen.getByText('All good')).toBeInTheDocument();
  });
});

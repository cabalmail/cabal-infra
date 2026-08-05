import { renderHook, act } from '@testing-library/react';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import useModalDismiss from './useModalDismiss';

function pressEscape() {
  act(() => {
    document.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape' }));
  });
}

function pressKey(key) {
  act(() => {
    document.dispatchEvent(new window.KeyboardEvent('keydown', { key }));
  });
}

describe('useModalDismiss', () => {
  let button;

  beforeEach(() => {
    button = document.createElement('button');
    document.body.appendChild(button);
  });

  afterEach(() => {
    button.remove();
  });

  it('dismisses on Escape while open', () => {
    const onDismiss = vi.fn();
    renderHook(() => useModalDismiss(true, onDismiss));
    pressEscape();
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });

  it('keeps Escape from reaching the handlers behind it', () => {
    // Stands in for useKeyboardShortcuts: a document-level bubble listener
    // installed before the modal opened, which closes the reader on Escape.
    const behind = vi.fn();
    document.addEventListener('keydown', behind);
    const onDismiss = vi.fn();
    try {
      renderHook(() => useModalDismiss(true, onDismiss));
      act(() => {
        button.dispatchEvent(
          new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
        );
      });
      expect(onDismiss).toHaveBeenCalledTimes(1);
      expect(behind).not.toHaveBeenCalled();
    } finally {
      document.removeEventListener('keydown', behind);
    }
  });

  it('lets other keys through to the handlers behind it', () => {
    const behind = vi.fn();
    document.addEventListener('keydown', behind);
    try {
      renderHook(() => useModalDismiss(true, vi.fn()));
      act(() => {
        button.dispatchEvent(
          new window.KeyboardEvent('keydown', { key: 'j', bubbles: true }),
        );
      });
      expect(behind).toHaveBeenCalledTimes(1);
    } finally {
      document.removeEventListener('keydown', behind);
    }
  });

  it('ignores other keys', () => {
    const onDismiss = vi.fn();
    renderHook(() => useModalDismiss(true, onDismiss));
    pressKey('Enter');
    pressKey('a');
    expect(onDismiss).not.toHaveBeenCalled();
  });

  it('does not listen while closed', () => {
    const onDismiss = vi.fn();
    renderHook(() => useModalDismiss(false, onDismiss));
    pressEscape();
    expect(onDismiss).not.toHaveBeenCalled();
  });

  it('detaches the listener when it closes', () => {
    const onDismiss = vi.fn();
    const { rerender } = renderHook(
      ({ open }) => useModalDismiss(open, onDismiss),
      { initialProps: { open: true } }
    );
    rerender({ open: false });
    pressEscape();
    expect(onDismiss).not.toHaveBeenCalled();
  });

  it('detaches the listener on unmount', () => {
    const onDismiss = vi.fn();
    const { unmount } = renderHook(() => useModalDismiss(true, onDismiss));
    unmount();
    pressEscape();
    expect(onDismiss).not.toHaveBeenCalled();
  });

  it('focuses focusRef when it opens', () => {
    const { result, rerender } = renderHook(
      ({ open }) => useModalDismiss(open, () => {}),
      { initialProps: { open: false } }
    );
    result.current.focusRef.current = button;
    expect(document.activeElement).not.toBe(button);
    rerender({ open: true });
    expect(document.activeElement).toBe(button);
  });

  it('tolerates an unattached focusRef', () => {
    const { rerender } = renderHook(
      ({ open }) => useModalDismiss(open, () => {}),
      { initialProps: { open: false } }
    );
    expect(() => rerender({ open: true })).not.toThrow();
  });

  it('dismisses on a scrim hit but not on a hit inside the window', () => {
    const onDismiss = vi.fn();
    const { result } = renderHook(() => useModalDismiss(true, onDismiss));
    const scrim = {};
    result.current.onScrimHit({ target: scrim, currentTarget: scrim });
    expect(onDismiss).toHaveBeenCalledTimes(1);
    result.current.onScrimHit({ target: {}, currentTarget: scrim });
    expect(onDismiss).toHaveBeenCalledTimes(1);
  });
});

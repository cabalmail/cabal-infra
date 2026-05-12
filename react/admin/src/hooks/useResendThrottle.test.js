import { renderHook, act } from '@testing-library/react';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import useResendThrottle from './useResendThrottle';

const STORAGE_KEY = 'cabalmail.resend.v1';

describe('useResendThrottle', () => {
  beforeEach(() => {
    window.localStorage.clear();
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-05-12T12:00:00Z'));
  });

  afterEach(() => {
    vi.useRealTimers();
    window.localStorage.clear();
  });

  it('starts unlocked', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    expect(result.current.locked).toBe(false);
    expect(result.current.lockoutRemaining).toBe(0);
  });

  it('recordLimitHit() locks for ~1 hour', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => result.current.recordLimitHit());
    expect(result.current.locked).toBe(true);
    expect(result.current.lockoutRemaining).toBeGreaterThan(60 * 59);
    expect(result.current.lockoutRemaining).toBeLessThanOrEqual(60 * 60);
  });

  it('does not impose any cooldown on its own - only Cognito-driven lockouts', () => {
    // Nothing in the hook's API hands out a cooldown without a
    // recordLimitHit() call from the caller. This test guards against
    // a regression where someone re-introduces a client-side schedule.
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    expect(result.current.locked).toBe(false);
    expect(Object.keys(result.current).sort()).toEqual([
      'locked',
      'lockoutRemaining',
      'recordLimitHit',
      'reset',
    ]);
  });

  it('clears the lockout once the window expires', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => result.current.recordLimitHit());
    expect(result.current.locked).toBe(true);
    act(() => {
      vi.advanceTimersByTime(60 * 60 * 1000 + 1000);
    });
    expect(result.current.locked).toBe(false);
    expect(result.current.lockoutRemaining).toBe(0);
  });

  it('persists the lockout across remount via localStorage', () => {
    const first = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => first.result.current.recordLimitHit());
    expect(first.result.current.locked).toBe(true);
    first.unmount();

    const second = renderHook(() => useResendThrottle('signup', 'alice'));
    expect(second.result.current.locked).toBe(true);
  });

  it('does not bleed state between different usernames', () => {
    const alice = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => alice.result.current.recordLimitHit());
    expect(alice.result.current.locked).toBe(true);
    alice.unmount();

    const bob = renderHook(() => useResendThrottle('signup', 'bob'));
    expect(bob.result.current.locked).toBe(false);
  });

  it('does not bleed state between flows for the same username', () => {
    const signup = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => signup.result.current.recordLimitHit());
    signup.unmount();

    const reset = renderHook(() => useResendThrottle('reset', 'alice'));
    expect(reset.result.current.locked).toBe(false);
  });

  it('reset() returns the throttle to a pristine state and clears storage', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => result.current.recordLimitHit());
    expect(window.localStorage.getItem(STORAGE_KEY)).not.toBeNull();
    act(() => result.current.reset());
    expect(result.current.locked).toBe(false);
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull();
  });

  it('lockoutRemaining ticks down with elapsed time', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => result.current.recordLimitHit());
    const initial = result.current.lockoutRemaining;
    act(() => {
      vi.advanceTimersByTime(10 * 1000);
    });
    expect(result.current.lockoutRemaining).toBeLessThanOrEqual(initial - 9);
  });
});

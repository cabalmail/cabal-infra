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

  it('starts in a pristine, ready-to-resend state', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    expect(result.current.cooldownSeconds).toBe(0);
    expect(result.current.locked).toBe(false);
    expect(result.current.canResend).toBe(true);
  });

  it('refuses to resend without a username', () => {
    const { result } = renderHook(() => useResendThrottle('signup', ''));
    expect(result.current.canResend).toBe(false);
  });

  it('imposes a 30s cooldown after the first resend', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => result.current.recordResend());
    expect(result.current.cooldownSeconds).toBe(30);
    expect(result.current.canResend).toBe(false);
  });

  it('escalates the cooldown through the schedule', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    const schedule = [30, 60, 120, 300];
    schedule.forEach((expected) => {
      act(() => {
        // Burn off the prior cooldown so the next click is allowed.
        vi.advanceTimersByTime(5 * 60 * 1000 + 1000);
        result.current.recordResend();
      });
      expect(result.current.cooldownSeconds).toBe(expected);
    });
  });

  it('locks out after the schedule is exhausted', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    // Five resends: the first four follow the schedule, the fifth trips
    // the lockout.
    for (let i = 0; i < 5; i += 1) {
      act(() => {
        vi.advanceTimersByTime(10 * 60 * 1000);
        result.current.recordResend();
      });
    }
    expect(result.current.locked).toBe(true);
    expect(result.current.lockoutRemaining).toBeGreaterThan(0);
    expect(result.current.lockoutRemaining).toBeLessThanOrEqual(60 * 60);
    expect(result.current.canResend).toBe(false);
  });

  it('clears the lockout once the lockout window expires', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    for (let i = 0; i < 5; i += 1) {
      act(() => {
        vi.advanceTimersByTime(10 * 60 * 1000);
        result.current.recordResend();
      });
    }
    expect(result.current.locked).toBe(true);
    act(() => {
      vi.advanceTimersByTime(60 * 60 * 1000 + 1000);
    });
    expect(result.current.locked).toBe(false);
    expect(result.current.canResend).toBe(true);
  });

  it('persists across remount via localStorage', () => {
    const first = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => first.result.current.recordResend());
    expect(first.result.current.cooldownSeconds).toBe(30);
    first.unmount();

    const second = renderHook(() => useResendThrottle('signup', 'alice'));
    expect(second.result.current.cooldownSeconds).toBe(30);
  });

  it('does not bleed state between different usernames', () => {
    const alice = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => alice.result.current.recordResend());
    expect(alice.result.current.cooldownSeconds).toBe(30);
    alice.unmount();

    const bob = renderHook(() => useResendThrottle('signup', 'bob'));
    expect(bob.result.current.cooldownSeconds).toBe(0);
    expect(bob.result.current.canResend).toBe(true);
  });

  it('does not bleed state between flows for the same username', () => {
    const signup = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => signup.result.current.recordResend());
    signup.unmount();

    const reset = renderHook(() => useResendThrottle('reset', 'alice'));
    expect(reset.result.current.cooldownSeconds).toBe(0);
    expect(reset.result.current.canResend).toBe(true);
  });

  it('reset() returns the throttle to a pristine state and clears storage', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => result.current.recordResend());
    expect(window.localStorage.getItem(STORAGE_KEY)).not.toBeNull();
    act(() => result.current.reset());
    expect(result.current.cooldownSeconds).toBe(0);
    expect(result.current.canResend).toBe(true);
    expect(window.localStorage.getItem(STORAGE_KEY)).toBeNull();
  });

  it('cooldown ticks down with elapsed time', () => {
    const { result } = renderHook(() => useResendThrottle('signup', 'alice'));
    act(() => result.current.recordResend());
    expect(result.current.cooldownSeconds).toBe(30);
    act(() => {
      vi.advanceTimersByTime(10 * 1000);
    });
    expect(result.current.cooldownSeconds).toBeLessThanOrEqual(20);
    act(() => {
      vi.advanceTimersByTime(25 * 1000);
    });
    expect(result.current.cooldownSeconds).toBe(0);
    expect(result.current.canResend).toBe(true);
  });
});

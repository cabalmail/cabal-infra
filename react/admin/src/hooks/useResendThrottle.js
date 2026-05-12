import { useCallback, useEffect, useState } from 'react';

const STORAGE_KEY = 'cabalmail.resend.v1';

// Cooldown schedule (seconds) keyed by resend count. The Nth click
// applies COOLDOWNS[N-1] before another resend is allowed. After the
// last entry is exhausted, the next attempt trips LOCKOUT_SECONDS.
const COOLDOWNS = [30, 60, 120, 300];
const LOCKOUT_SECONDS = 60 * 60;

function now() {
  return Date.now();
}

function readStored() {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') return null;
    return parsed;
  } catch {
    return null;
  }
}

function writeStored(state) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch {
    /* quota / disabled storage - throttle still works in-memory */
  }
}

function clearStored() {
  try {
    window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    /* ignore */
  }
}

function emptyState(key) {
  return { key, count: 0, nextAt: 0, lockedUntil: 0 };
}

function loadFor(key) {
  const stored = readStored();
  if (!stored || stored.key !== key) {
    return emptyState(key);
  }
  // Lockout expired since last visit? Reset so the user gets a fresh
  // window rather than being told they're still locked out.
  if (stored.lockedUntil && stored.lockedUntil <= now()) {
    return emptyState(key);
  }
  return {
    key,
    count: Number(stored.count) || 0,
    nextAt: Number(stored.nextAt) || 0,
    lockedUntil: Number(stored.lockedUntil) || 0,
  };
}

/**
 * Throttles "resend verification code" clicks on signup / forgot-password.
 *
 * After each resend the user must wait COOLDOWNS[count-1] seconds before
 * clicking again; the schedule escalates 30s -> 60s -> 120s -> 300s.
 * Past the last entry the next attempt trips a one-hour lockout. State
 * is persisted to localStorage so a page refresh doesn't hand the user
 * a fresh budget. The `key` (flow + username) scopes the throttle so
 * starting a different account doesn't inherit a stranger's counter.
 *
 * `flow`     - one of 'signup' | 'reset', so signup and forgot-password
 *              don't share a counter.
 * `username` - included in the storage key. Falsy username yields a
 *              permanently-locked-out result; the caller should mount
 *              the hook only once a username is known.
 */
export default function useResendThrottle(flow, username) {
  const key = `${flow}:${username || ''}`;
  const [state, setState] = useState(() => loadFor(key));
  const [tick, setTick] = useState(0);

  // Re-initialise when the (flow, username) pair changes - e.g. user
  // backs out, switches account, and starts a fresh signup.
  useEffect(() => {
    setState(loadFor(key));
  }, [key]);

  // Tick once a second while there is something to count down. When
  // nothing's pending we leave the interval off so we don't churn the
  // event loop on the Login screen.
  useEffect(() => {
    const pending = state.nextAt > now() || state.lockedUntil > now();
    if (!pending) return undefined;
    const id = setInterval(() => setTick(t => t + 1), 1000);
    return () => clearInterval(id);
  }, [state.nextAt, state.lockedUntil, tick]);

  // Persist whenever state changes (except when it's been reset to a
  // pristine empty state for a known key, in which case drop the
  // storage entry so unrelated flows start clean).
  useEffect(() => {
    if (state.count === 0 && state.lockedUntil === 0 && state.nextAt === 0) {
      clearStored();
      return;
    }
    writeStored(state);
  }, [state]);

  // Lockout window expired in the background? Promote to a fresh state.
  useEffect(() => {
    if (state.lockedUntil && state.lockedUntil <= now()) {
      setState(emptyState(key));
    }
  }, [tick, state.lockedUntil, key]);

  const cooldownSeconds = state.nextAt > now()
    ? Math.ceil((state.nextAt - now()) / 1000)
    : 0;
  const lockoutRemaining = state.lockedUntil > now()
    ? Math.ceil((state.lockedUntil - now()) / 1000)
    : 0;
  const locked = lockoutRemaining > 0;
  const canResend = !locked && cooldownSeconds === 0 && Boolean(username);

  const recordResend = useCallback(() => {
    setState(prev => {
      // Already locked out: clicking again shouldn't extend the lockout
      // - just no-op. The UI shouldn't have called us in that state but
      // belt-and-braces.
      if (prev.lockedUntil > now()) return prev;
      const nextCount = prev.count + 1;
      // Past the cooldown schedule = lockout.
      if (nextCount > COOLDOWNS.length) {
        return {
          ...prev,
          count: nextCount,
          nextAt: 0,
          lockedUntil: now() + LOCKOUT_SECONDS * 1000,
        };
      }
      return {
        ...prev,
        count: nextCount,
        nextAt: now() + COOLDOWNS[nextCount - 1] * 1000,
        lockedUntil: 0,
      };
    });
  }, []);

  const reset = useCallback(() => {
    setState(emptyState(key));
  }, [key]);

  return {
    cooldownSeconds,
    locked,
    lockoutRemaining,
    canResend,
    recordResend,
    reset,
  };
}

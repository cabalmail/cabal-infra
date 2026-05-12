import { useCallback, useEffect, useState } from 'react';

const STORAGE_KEY = 'cabalmail.resend.v1';

// Cognito enforces ~5 resends per user per hour and returns
// LimitExceededException once that window is exceeded. We don't know
// the precise rolling-window semantics on Cognito's side, so we just
// hold the lockout for an hour from the moment we saw the error and
// then let the user try again. If Cognito still says no, we'll get
// LimitExceededException again and the state refreshes.
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
  return { key, lockedUntil: 0 };
}

function loadFor(key) {
  const stored = readStored();
  if (!stored || stored.key !== key) {
    return emptyState(key);
  }
  if (stored.lockedUntil && stored.lockedUntil <= now()) {
    return emptyState(key);
  }
  return { key, lockedUntil: Number(stored.lockedUntil) || 0 };
}

/**
 * Tracks the "Cognito told us we hit the resend rate limit" state
 * across page refreshes. Cognito enforces the actual policy (~5
 * resends per user per hour) and returns LimitExceededException
 * once it's exceeded; this hook persists that signal so the UI keeps
 * showing the lockout message even after a refresh, until an hour
 * has passed.
 *
 * The hook deliberately does not impose its own pre-emptive cooldown.
 * Cognito decides what's allowed; we just reflect what it tells us
 * so the user gets an accurate picture of what's happening.
 *
 * `flow`     - 'signup' | 'reset', so signup and forgot-password
 *              don't share a lockout.
 * `username` - included in the storage key so starting a different
 *              account doesn't inherit a stranger's lockout. Falsy
 *              usernames are accepted but the resulting state is
 *              effectively scratch.
 */
export default function useResendThrottle(flow, username) {
  const key = `${flow}:${username || ''}`;
  const [state, setState] = useState(() => loadFor(key));
  const [tick, setTick] = useState(0);

  useEffect(() => {
    setState(loadFor(key));
  }, [key]);

  // Tick once a second while the lockout is counting down so
  // lockoutRemaining stays current. No interval when nothing is
  // pending - the Login screen shouldn't churn.
  useEffect(() => {
    if (state.lockedUntil <= now()) return undefined;
    const id = setInterval(() => setTick(t => t + 1), 1000);
    return () => clearInterval(id);
  }, [state.lockedUntil, tick]);

  useEffect(() => {
    if (state.lockedUntil === 0) {
      clearStored();
      return;
    }
    writeStored(state);
  }, [state]);

  // Lockout expired in the background? Promote to a fresh state.
  useEffect(() => {
    if (state.lockedUntil && state.lockedUntil <= now()) {
      setState(emptyState(key));
    }
  }, [tick, state.lockedUntil, key]);

  const lockoutRemaining = state.lockedUntil > now()
    ? Math.ceil((state.lockedUntil - now()) / 1000)
    : 0;
  const locked = lockoutRemaining > 0;

  const recordLimitHit = useCallback(() => {
    setState(prev => ({ ...prev, lockedUntil: now() + LOCKOUT_SECONDS * 1000 }));
  }, []);

  const reset = useCallback(() => {
    setState(emptyState(key));
  }, [key]);

  return {
    locked,
    lockoutRemaining,
    recordLimitHit,
    reset,
  };
}

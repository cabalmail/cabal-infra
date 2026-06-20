import { useCallback, useEffect, useRef, useState } from 'react';

const STORAGE_KEY = 'cabalmail.displayname.v1';
const SAVE_DEBOUNCE_MS = 1000;

// Mirrors the set_preferences Lambda's validation: control characters are
// rejected server-side (they would be a header-injection vector at send
// time) and length is capped at 100. Trimming is left to the server so
// typing a space mid-name doesn't fight the input.
const MAX_LENGTH = 100;

function sanitize(value) {
  if (typeof value !== 'string') return '';
  // eslint-disable-next-line no-control-regex
  return value.replace(/[\u0000-\u001f\u007f]/g, '').slice(0, MAX_LENGTH);
}

function readStoredName() {
  try {
    return sanitize(window.localStorage.getItem(STORAGE_KEY) || '');
  } catch {
    return '';
  }
}

function writeStoredName(name) {
  try {
    window.localStorage.setItem(STORAGE_KEY, name);
  } catch {
    /* quota or disabled storage — the name simply won't persist locally */
  }
}

/**
 * Reads and writes the user's display name preference. The /send Lambda
 * composes the From header server-side from this preference, so this hook
 * only manages the setting itself, not outgoing mail.
 *
 * Follows the useTheme pattern: localStorage is the fast path for initial
 * render and offline, the `get_preferences` Lambda hydrates on mount, and
 * edits save via `set_preferences` debounced at 1s. The save payload is
 * `{name}` only — set_preferences merges per-key, so this never clobbers
 * theme preferences saved elsewhere.
 */
export default function useDisplayName(apiClient) {
  const [name, setNameState] = useState(readStoredName);
  const hasHydrated = useRef(false);
  const saveTimer = useRef(null);

  // Mirror to localStorage so the next session renders instantly.
  useEffect(() => {
    writeStoredName(name);
  }, [name]);

  // Hydrate from API once an authenticated ApiClient becomes available.
  useEffect(() => {
    if (!apiClient || hasHydrated.current) return undefined;
    let cancelled = false;
    apiClient.getPreferences()
      .then(({ data }) => {
        if (cancelled) return;
        hasHydrated.current = true;
        const remote = sanitize(data && data.name);
        setNameState((prev) => (prev === remote ? prev : remote));
      })
      .catch(() => {
        // Network / auth failure — keep the localStorage value; leaving
        // hasHydrated=false lets a later mount retry.
      });
    return () => { cancelled = true; };
  }, [apiClient]);

  // Debounced save to API. Only fires once hydration has completed so the
  // hydrated value isn't echoed straight back.
  useEffect(() => {
    if (!apiClient || !hasHydrated.current) return undefined;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      apiClient.putPreferences({ name }).catch(() => { /* transient failure ok */ });
    }, SAVE_DEBOUNCE_MS);
    return () => {
      if (saveTimer.current) clearTimeout(saveTimer.current);
    };
  }, [apiClient, name]);

  const setName = useCallback((value) => {
    const next = sanitize(value);
    setNameState((prev) => (prev === next ? prev : next));
  }, []);

  return { name, setName };
}

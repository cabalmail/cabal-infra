import { useCallback, useEffect, useRef, useState } from 'react';

const STORAGE_KEY = 'cabalmail.theme.v1';
const DIRECTION = 'stately';
const SAVE_DEBOUNCE_MS = 1000;

const DEFAULTS = {
  theme: 'light',
  accent: 'forest',
  density: 'compact',
};

const VALID = {
  theme: ['light', 'dark'],
  accent: ['ink', 'oxblood', 'forest', 'azure', 'amber', 'plum'],
  density: ['compact', 'normal', 'roomy'],
};

function sanitize(input) {
  if (!input || typeof input !== 'object') return { ...DEFAULTS };
  return {
    theme:   VALID.theme.includes(input.theme)     ? input.theme   : DEFAULTS.theme,
    accent:  VALID.accent.includes(input.accent)   ? input.accent  : DEFAULTS.accent,
    density: VALID.density.includes(input.density) ? input.density : DEFAULTS.density,
  };
}

function readStoredPrefs() {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return { ...DEFAULTS };
    return sanitize(JSON.parse(raw));
  } catch {
    return { ...DEFAULTS };
  }
}

function writeStoredPrefs(prefs) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(prefs));
  } catch {
    /* quota or disabled storage — theme simply won't persist across reloads */
  }
}

/**
 * Reads and writes theme / accent / density preferences, and syncs them
 * to `data-direction` / `data-theme` / `data-accent` / `data-density`
 * attributes on the document root so CSS custom properties resolve.
 *
 * Phase 7: when an ApiClient is provided, preferences load from the
 * `get_preferences` Lambda on mount and save via `set_preferences`
 * debounced at 1s. localStorage is always the fast path for initial
 * render and offline.
 */
export default function useTheme(apiClient) {
  const [prefs, setPrefs] = useState(readStoredPrefs);
  const hasHydrated = useRef(false);
  const saveTimer = useRef(null);

  // Push prefs onto the root and mirror to localStorage for instant-apply.
  useEffect(() => {
    const root = document.documentElement;
    root.setAttribute('data-direction', DIRECTION);
    root.setAttribute('data-theme',   prefs.theme);
    root.setAttribute('data-accent',  prefs.accent);
    root.setAttribute('data-density', prefs.density);
    writeStoredPrefs(prefs);
  }, [prefs]);

  // Hydrate from API once an authenticated ApiClient becomes available.
  useEffect(() => {
    if (!apiClient || hasHydrated.current) return;
    let cancelled = false;
    apiClient.getPreferences()
      .then(({ data }) => {
        if (cancelled) return;
        hasHydrated.current = true;
        const remote = sanitize(data);
        setPrefs((prev) => (
          prev.theme === remote.theme
            && prev.accent === remote.accent
            && prev.density === remote.density
          ? prev
          : remote
        ));
      })
      .catch(() => {
        // Network / auth failure — keep localStorage values; allow future
        // mounts to retry. Leaving hasHydrated=false means a fresh login
        // with working network will still sync.
      });
    return () => { cancelled = true; };
  }, [apiClient]);

  // Debounced save to API. Waits 1s after the last change, and only fires
  // once hydration has completed so the initial hydrated value isn't echoed
  // straight back.
  useEffect(() => {
    if (!apiClient || !hasHydrated.current) return undefined;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      apiClient.putPreferences(prefs).catch(() => { /* transient failure ok */ });
    }, SAVE_DEBOUNCE_MS);
    return () => {
      if (saveTimer.current) clearTimeout(saveTimer.current);
    };
  }, [apiClient, prefs]);

  const setTheme = useCallback((theme) => {
    if (!VALID.theme.includes(theme)) return;
    setPrefs((prev) => (prev.theme === theme ? prev : { ...prev, theme }));
  }, []);

  const setAccent = useCallback((accent) => {
    if (!VALID.accent.includes(accent)) return;
    setPrefs((prev) => (prev.accent === accent ? prev : { ...prev, accent }));
  }, []);

  const setDensity = useCallback((density) => {
    if (!VALID.density.includes(density)) return;
    setPrefs((prev) => (prev.density === density ? prev : { ...prev, density }));
  }, []);

  const toggleTheme = useCallback(() => {
    setPrefs((prev) => ({ ...prev, theme: prev.theme === 'dark' ? 'light' : 'dark' }));
  }, []);

  return {
    direction: DIRECTION,
    theme:    prefs.theme,
    accent:   prefs.accent,
    density:  prefs.density,
    setTheme,
    setAccent,
    setDensity,
    toggleTheme,
    accents:    VALID.accent,
    densities:  VALID.density,
  };
}

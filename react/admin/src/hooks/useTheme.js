import { useCallback, useEffect, useState } from 'react';

const STORAGE_KEY = 'cabalmail.theme.v1';
const DIRECTION = 'stately';

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

function readStoredPrefs() {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return { ...DEFAULTS };
    const parsed = JSON.parse(raw);
    return {
      theme:   VALID.theme.includes(parsed.theme)     ? parsed.theme   : DEFAULTS.theme,
      accent:  VALID.accent.includes(parsed.accent)   ? parsed.accent  : DEFAULTS.accent,
      density: VALID.density.includes(parsed.density) ? parsed.density : DEFAULTS.density,
    };
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
 * localStorage-only in Phase 1. Cognito sync lands in Phase 7.
 */
export default function useTheme() {
  const [prefs, setPrefs] = useState(readStoredPrefs);

  useEffect(() => {
    const root = document.documentElement;
    root.setAttribute('data-direction', DIRECTION);
    root.setAttribute('data-theme',   prefs.theme);
    root.setAttribute('data-accent',  prefs.accent);
    root.setAttribute('data-density', prefs.density);
    writeStoredPrefs(prefs);
  }, [prefs]);

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

import '@testing-library/jest-dom';
import { cleanup } from '@testing-library/react';
import { afterEach } from 'vitest';

// React Testing Library's auto-cleanup does not fire reliably under
// `pool: 'forks'` with `singleFork: true` (the jsdom document is shared
// across test files in the same fork, and RTL's per-file afterEach hook
// can miss mounts from the previous file). Register cleanup explicitly.
afterEach(() => {
  cleanup();
});

// Mock IntersectionObserver for jsdom (used by react-intersection-observer)
class IntersectionObserver {
  constructor(callback) {
    this._callback = callback;
  }
  observe() {}
  unobserve() {}
  disconnect() {}
}
global.IntersectionObserver = IntersectionObserver;

// jsdom doesn't implement matchMedia; default to "nothing matches" so components
// using useMediaQuery render their mobile-first base styles. Individual tests
// override this (see setViewport helper in src/test/viewport.js) to simulate
// phone / tablet / desktop breakpoints.
if (typeof window !== 'undefined' && !window.matchMedia) {
  window.matchMedia = (query) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  });
}

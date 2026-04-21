import '@testing-library/jest-dom';

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

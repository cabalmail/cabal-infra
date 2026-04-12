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

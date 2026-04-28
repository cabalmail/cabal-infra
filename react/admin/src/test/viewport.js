// Helpers for viewport-specific tests. Installs a matchMedia mock that
// resolves media queries against a fake window width in pixels.
//
// Phases of the redesign define three breakpoints:
//   phone    — width <  768
//   tablet   — width >= 768 and < 1200
//   desktop  — width >= 1200

export function setViewport(width, height = 900) {
  Object.defineProperty(window, 'innerWidth', {
    configurable: true,
    writable: true,
    value: width,
  });
  Object.defineProperty(window, 'innerHeight', {
    configurable: true,
    writable: true,
    value: height,
  });
  window.matchMedia = (query) => {
    const matches = evalQuery(query, width);
    const listeners = new Set();
    return {
      matches,
      media: query,
      onchange: null,
      addListener: (l) => listeners.add(l),
      removeListener: (l) => listeners.delete(l),
      addEventListener: (_, l) => listeners.add(l),
      removeEventListener: (_, l) => listeners.delete(l),
      dispatchEvent: () => false,
    };
  };
}

function evalQuery(query, width) {
  // Supports simple single-feature "(min-width: Npx)" / "(max-width: Npx)" queries.
  const min = query.match(/min-width:\s*(\d+)px/);
  if (min) return width >= Number(min[1]);
  const max = query.match(/max-width:\s*(\d+)px/);
  if (max) return width <= Number(max[1]);
  return false;
}

export const PHONE = [375, 812];
export const TABLET = [834, 1194];
export const DESKTOP = [1440, 900];

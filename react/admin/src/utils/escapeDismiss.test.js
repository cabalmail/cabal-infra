import { describe, it, expect } from 'vitest';
import topmostDismissal from './escapeDismiss';

describe('topmostDismissal', () => {
  it('dismisses the composer, not the reader, when both are open', () => {
    expect(topmostDismissal({ overlayVisible: true, composeWindows: [{ id: 7 }] }))
      .toEqual({ kind: 'compose', id: 7 });
  });

  it('dismisses the most recently opened composer first', () => {
    expect(topmostDismissal({
      overlayVisible: true,
      composeWindows: [{ id: 1 }, { id: 2 }, { id: 3 }],
    })).toEqual({ kind: 'compose', id: 3 });
  });

  it('falls through to the reader once every composer is gone', () => {
    expect(topmostDismissal({ overlayVisible: true, composeWindows: [] }))
      .toEqual({ kind: 'reader' });
  });

  it('dismisses the composer when no message is open', () => {
    expect(topmostDismissal({ overlayVisible: false, composeWindows: [{ id: 4 }] }))
      .toEqual({ kind: 'compose', id: 4 });
  });

  it('reports nothing to dismiss when neither layer is up', () => {
    expect(topmostDismissal({ overlayVisible: false, composeWindows: [] })).toBeNull();
  });

  it('tolerates a missing compose list', () => {
    expect(topmostDismissal({ overlayVisible: true })).toEqual({ kind: 'reader' });
    expect(topmostDismissal({ overlayVisible: false })).toBeNull();
  });
});

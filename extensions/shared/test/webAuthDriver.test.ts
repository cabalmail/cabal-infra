import { describe, expect, it, vi } from 'vitest';
import { tabDriver, type TabsLike } from '../src/auth/webAuthDriver';

const REDIRECT = 'https://admin.cabal-mail.example/extension-auth';

function fakeTabs() {
  const updatedListeners = new Set<(tabId: number, info: { url?: string }) => void>();
  const removedListeners = new Set<(tabId: number) => void>();
  const removed: number[] = [];
  const tabs: TabsLike = {
    create: vi.fn(async () => ({ id: 7 })),
    remove: vi.fn(async (id: number) => {
      removed.push(id);
    }),
    onUpdated: {
      addListener: (cb) => updatedListeners.add(cb),
      removeListener: (cb) => updatedListeners.delete(cb),
    },
    onRemoved: {
      addListener: (cb) => removedListeners.add(cb),
      removeListener: (cb) => removedListeners.delete(cb),
    },
  };
  return {
    tabs,
    removed,
    emitUpdated: (tabId: number, url?: string) =>
      updatedListeners.forEach((cb) => cb(tabId, { url })),
    emitRemoved: (tabId: number) => removedListeners.forEach((cb) => cb(tabId)),
    listenerCount: () => updatedListeners.size + removedListeners.size,
  };
}

describe('tabDriver', () => {
  it('reports the configured redirect URI', () => {
    expect(tabDriver(REDIRECT, fakeTabs().tabs).redirectUri()).toBe(REDIRECT);
  });

  it('resolves with the redirect URL and closes the auth tab', async () => {
    const f = fakeTabs();
    const flow = tabDriver(REDIRECT, f.tabs).authorize('https://auth.example/authorize');
    await Promise.resolve(); // let create() settle
    f.emitUpdated(7, 'https://consent.page/'); // unrelated navigation ignored
    f.emitUpdated(3, `${REDIRECT}?code=x`); // wrong tab ignored
    f.emitUpdated(7, `${REDIRECT}?code=abc&state=s`);
    await expect(flow).resolves.toBe(`${REDIRECT}?code=abc&state=s`);
    expect(f.removed).toEqual([7]);
    expect(f.listenerCount()).toBe(0);
  });

  it('rejects when the user closes the sign-in tab', async () => {
    const f = fakeTabs();
    const flow = tabDriver(REDIRECT, f.tabs).authorize('https://auth.example/authorize');
    await Promise.resolve();
    f.emitRemoved(7);
    await expect(flow).rejects.toThrow('sign-in tab was closed');
    expect(f.listenerCount()).toBe(0);
  });

  it('times out and cleans up if the flow is abandoned', async () => {
    vi.useFakeTimers();
    try {
      const f = fakeTabs();
      const flow = tabDriver(REDIRECT, f.tabs).authorize('https://auth.example/authorize');
      const expectation = expect(flow).rejects.toThrow('sign-in timed out');
      await vi.advanceTimersByTimeAsync(5 * 60 * 1000 + 1);
      await expectation;
      expect(f.removed).toEqual([7]);
      expect(f.listenerCount()).toBe(0);
    } finally {
      vi.useRealTimers();
    }
  });

  it('rejects when a tab cannot be opened', async () => {
    const f = fakeTabs();
    (f.tabs.create as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('nope'));
    await expect(
      tabDriver(REDIRECT, f.tabs).authorize('https://auth.example/authorize'),
    ).rejects.toThrow('nope');
    expect(f.listenerCount()).toBe(0);
  });
});

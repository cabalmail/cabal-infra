/**
 * Test stand-in for webextension-polyfill, which refuses to load outside a
 * real extension context. Suites that exercise other browser APIs inject
 * their own fakes (e.g. TabsLike); `storage.local` is implemented here
 * because it is not injectable -- token and pending-flow persistence reach
 * for it directly, the way the real extension does.
 */

const store = new Map<string, unknown>();

export function resetStorage(): void {
  store.clear();
}

export default {
  storage: {
    local: {
      get: async (key: string) =>
        store.has(key) ? { [key]: store.get(key) } : ({} as Record<string, unknown>),
      set: async (items: Record<string, unknown>) => {
        for (const [k, v] of Object.entries(items)) store.set(k, v);
      },
      remove: async (key: string) => {
        store.delete(key);
      },
    },
  },
};

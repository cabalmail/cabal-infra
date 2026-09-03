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
  nativeResponder = null;
}

/**
 * Test hook for `runtime.sendNativeMessage` (the embedded Safari build asks
 * its containing mail app for the control domain). Null -- the default --
 * makes the call reject, which is what Chrome and the standalone host do.
 */
let nativeResponder: ((message: unknown) => unknown) | null = null;

export function setNativeResponder(fn: ((message: unknown) => unknown) | null): void {
  nativeResponder = fn;
}

export default {
  runtime: {
    sendNativeMessage: async (_app: string, message: unknown) => {
      if (!nativeResponder) throw new Error('no native host');
      return nativeResponder(message);
    },
  },
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

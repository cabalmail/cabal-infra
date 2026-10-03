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

/**
 * Listeners the background registers at import, and the browser calls it
 * makes -- enough of the surface to drive `tabs.onUpdated` the way a
 * navigation does. Registration happens once per process (the module is
 * imported once), so `resetStorage` deliberately leaves `listeners` alone
 * and only `resetCalls` clears what a case recorded.
 */
export const listeners = {
  tabsUpdated: [] as ((tabId: number, changeInfo: { url?: string }) => void)[],
};

export const calls = {
  windowsCreated: [] as { incognito?: boolean; url?: string }[],
  tabsRemoved: [] as number[],
  historyDeleted: [] as { url?: string }[],
};

export function resetCalls(): void {
  calls.windowsCreated.length = 0;
  calls.tabsRemoved.length = 0;
  calls.historyDeleted.length = 0;
}

/**
 * `history` is absent by default, which is Safari: WebKit implements no
 * `history` API, so the namespace is simply not there (#1765). Chrome's
 * arm installs it.
 */
export function setHistoryApi(present: boolean): void {
  stub.history = present
    ? {
        deleteUrl: async (details: { url?: string }) => {
          calls.historyDeleted.push(details);
        },
      }
    : undefined;
}

const stub: {
  history?: { deleteUrl: (details: { url?: string }) => Promise<void> };
  [key: string]: unknown;
} = {
  runtime: {
    sendNativeMessage: async (_app: string, message: unknown) => {
      if (!nativeResponder) throw new Error('no native host');
      return nativeResponder(message);
    },
    onMessage: {
      addListener: () => {},
    },
  },
  tabs: {
    onUpdated: {
      addListener: (fn: (tabId: number, changeInfo: { url?: string }) => void) => {
        listeners.tabsUpdated.push(fn);
      },
    },
    remove: async (tabId: number) => {
      calls.tabsRemoved.push(tabId);
    },
  },
  windows: {
    create: async (options: { incognito?: boolean; url?: string }) => {
      calls.windowsCreated.push(options);
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

export default stub;

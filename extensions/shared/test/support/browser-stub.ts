/**
 * Test stand-in for webextension-polyfill, which refuses to load outside a
 * real extension context. Suites that exercise browser APIs inject their
 * own fakes (e.g. TabsLike); this stub only has to make the module
 * importable.
 */
export default {} as Record<string, never>;

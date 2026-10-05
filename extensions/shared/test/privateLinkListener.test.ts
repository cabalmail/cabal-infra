/**
 * The background's `tabs.onUpdated` handler, end to end on this side of
 * the bridge: a redirector navigation in, a private window out.
 *
 * The composition is what #1765 broke, not any one function: the scrub
 * that was supposed to follow the handoff silently did nothing on Safari,
 * and the fix changes what the fragment carries. So drive the real
 * listener the real module registers, with the stub standing in for the
 * browser -- including the absence of `browser.history`, which is what
 * Safari actually presents.
 */

import { beforeEach, describe, expect, it } from 'vitest';
import { forgetNativeControlDomain, saveControlDomain } from '../src/config/controlDomain';
import {
  calls,
  listeners,
  resetCalls,
  resetStorage,
  setHistoryApi,
  setNativeResponder,
} from './support/browser-stub';
// Importing the background is what registers the listener.
import '../../chrome/src/background';

const DOMAIN = 'cabalmail.example';
const TOKEN = '0123456789abcdef0123456789abcdef';
const TAB = 7;

/** Deliver a navigation to every registered listener and let it settle. */
async function navigate(url: string): Promise<void> {
  expect(listeners.tabsUpdated.length).toBeGreaterThan(0);
  for (const listener of listeners.tabsUpdated) listener(TAB, { url });
  // The listener body is a detached async IIFE; a macrotask turn is
  // enough for the awaits in it (all of them resolve immediately here).
  await new Promise((resolve) => setTimeout(resolve, 0));
}

beforeEach(async () => {
  resetStorage();
  resetCalls();
  forgetNativeControlDomain();
  setHistoryApi(false);
  // Storage takes precedence over the native answer, so the domain is
  // settled without spending the native stub on it.
  await saveControlDomain(DOMAIN);
});

describe('the private-link listener', () => {
  it('opens a fragment-borne target privately and closes the redirector', async () => {
    setHistoryApi(true);
    await navigate(`https://admin.${DOMAIN}/private-link#https%3A%2F%2Fexample.com%2Fa`);
    expect(calls.windowsCreated).toEqual([{ incognito: true, url: 'https://example.com/a' }]);
    expect(calls.tabsRemoved).toEqual([TAB]);
    expect(calls.historyDeleted).toEqual([
      { url: `https://admin.${DOMAIN}/private-link#https%3A%2F%2Fexample.com%2Fa` },
    ]);
  });

  it('resolves a token over the bridge, opens it, and retires the row', async () => {
    const sent: unknown[] = [];
    setNativeResponder((message) => {
      sent.push(message);
      return { url: 'https://example.com/secret' };
    });
    await navigate(`https://admin.${DOMAIN}/private-link#${TOKEN}`);
    expect(calls.windowsCreated).toEqual([
      { incognito: true, url: 'https://example.com/secret' },
    ]);
    expect(calls.tabsRemoved).toEqual([TAB]);
    expect(sent).toEqual([
      { kind: 'resolve-private-link', token: TOKEN },
      { kind: 'forget-private-link', token: TOKEN },
    ]);
  });

  it('survives the missing history API instead of throwing into the catch', async () => {
    // Pre-fix this was `await browser.history?.deleteUrl(...)`, which
    // resolved to undefined and left no trace at all. Post-fix the call is
    // skipped explicitly; either way nothing may break the handoff, and
    // nothing may be deleted when there is no API to delete with.
    setNativeResponder(() => ({ url: 'https://example.com/secret' }));
    await navigate(`https://admin.${DOMAIN}/private-link#${TOKEN}`);
    expect(calls.windowsCreated).toHaveLength(1);
    expect(calls.historyDeleted).toEqual([]);
  });

  it('leaves a token nothing can resolve alone, so the page can explain', async () => {
    // No native responder: the call rejects, as it does in Chrome and in
    // the standalone Safari host.
    await navigate(`https://admin.${DOMAIN}/private-link#${TOKEN}`);
    expect(calls.windowsCreated).toEqual([]);
    expect(calls.tabsRemoved).toEqual([]);
  });

  it('never opens a target whose scheme is blocked, from either form', async () => {
    await navigate(
      `https://admin.${DOMAIN}/private-link#${encodeURIComponent('javascript:alert(1)')}`,
    );
    setNativeResponder(() => ({ url: 'javascript:alert(1)' }));
    await navigate(`https://admin.${DOMAIN}/private-link#${TOKEN}`);
    expect(calls.windowsCreated).toEqual([]);
  });

  it('ignores a navigation that is not the redirector', async () => {
    await navigate('https://example.com/ordinary');
    await navigate(`https://admin.${DOMAIN}/`);
    expect(calls.windowsCreated).toEqual([]);
    expect(calls.tabsRemoved).toEqual([]);
  });
});

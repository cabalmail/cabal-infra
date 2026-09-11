/**
 * Content-script entry: wires the shared ContentController to the real
 * background bridge and the Preact overlay, plus the pagehide best-effort
 * cleanup (Phase 5.4).
 */

import browser from 'webextension-polyfill';
import {
  ContentController,
  hostnameOf,
} from '@cabalmail/extension-shared/content/controller';
import { runtimeBackgroundPort } from '@cabalmail/extension-shared/messaging/client';
import { isPageRequest, type PageResponse } from '@cabalmail/extension-shared/messaging/messages';
import { createOverlay } from './overlay/overlay';

function main(): void {
  const controller = new ContentController(runtimeBackgroundPort(), createOverlay(), {
    url: window.location.href,
    document,
  });
  controller.start();
  window.addEventListener('pagehide', () => controller.onPageHide());
  // The popup's "Mint + copy" flow labels the new address with the page it
  // was minted for. Answering from here keeps the popup free of any tab
  // permission: tabs.sendMessage only reaches content scripts.
  browser.runtime.onMessage.addListener((message: unknown) => {
    if (!isPageRequest(message)) return undefined;
    const response: PageResponse = {
      kind: 'page-hostname',
      hostname: hostnameOf(window.location.href),
    };
    return Promise.resolve(response);
  });
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', main);
} else {
  main();
}

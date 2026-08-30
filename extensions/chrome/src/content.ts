/**
 * Content-script entry: wires the shared ContentController to the real
 * background bridge and the Preact overlay, plus the pagehide best-effort
 * cleanup (Phase 5.4).
 */

import { ContentController } from '@cabalmail/extension-shared/content/controller';
import { runtimeBackgroundPort } from '@cabalmail/extension-shared/messaging/client';
import { createOverlay } from './overlay/overlay';

function main(): void {
  const controller = new ContentController(runtimeBackgroundPort(), createOverlay(), {
    url: window.location.href,
    document,
  });
  controller.start();
  window.addEventListener('pagehide', () => controller.onPageHide());
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', main);
} else {
  main();
}

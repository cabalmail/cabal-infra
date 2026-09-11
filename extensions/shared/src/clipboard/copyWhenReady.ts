/**
 * Copy text that is not known until an async step finishes -- an address
 * that only exists once the server has created it -- without forfeiting the
 * user gesture that authorizes the write.
 *
 * Safari ties clipboard access to the click that started it, and an `await`
 * between the click and `writeText` is enough to lose it; Chrome's transient
 * activation is more forgiving but bounded too. A ClipboardItem may carry a
 * promise for its payload, which is the sanctioned way to say "authorize the
 * write now, supply the bytes later". Where that API is missing the fallback
 * writes after the payload resolves and takes its chances with the gesture
 * window, which is why the popup keeps a plain Copy button beside the result.
 *
 * Call this synchronously inside the click handler, before any await.
 * Resolves once the text is on the clipboard. Rejects if the payload promise
 * rejects (nothing is copied) or the browser refuses the write.
 */
export function copyWhenReady(text: Promise<string>): Promise<void> {
  const clipboard = navigator.clipboard;
  const Item = globalThis.ClipboardItem;
  if (typeof Item === 'function' && typeof clipboard.write === 'function') {
    const payload = text.then((value) => new Blob([value], { type: 'text/plain' }));
    return clipboard.write([new Item({ 'text/plain': payload })]);
  }
  return text.then((value) => clipboard.writeText(value));
}

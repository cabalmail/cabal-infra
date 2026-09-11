// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { copyWhenReady } from '../src/clipboard/copyWhenReady';

/**
 * jsdom ships neither `navigator.clipboard` nor `ClipboardItem`; each case
 * installs the shape it wants to exercise and tears it down afterwards.
 */
function installClipboard(clipboard: Partial<Clipboard>): void {
  Object.defineProperty(navigator, 'clipboard', { value: clipboard, configurable: true });
}

class FakeClipboardItem {
  constructor(public readonly items: Record<string, string | Blob | PromiseLike<string | Blob>>) {}
}

/** jsdom's Blob predates `Blob.text()`; FileReader is the portable read. */
function readBlob(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsText(blob);
  });
}

afterEach(() => {
  Reflect.deleteProperty(navigator, 'clipboard');
  Reflect.deleteProperty(globalThis, 'ClipboardItem');
});

describe('copyWhenReady', () => {
  it('hands the clipboard a ClipboardItem synchronously, before the payload resolves', async () => {
    const write = vi.fn(async () => {});
    installClipboard({ write });
    Object.defineProperty(globalThis, 'ClipboardItem', {
      value: FakeClipboardItem,
      configurable: true,
    });

    let release: (value: string) => void = () => {};
    const text = new Promise<string>((resolve) => {
      release = resolve;
    });
    const done = copyWhenReady(text);

    // The write is authorized inside the gesture: it has already been
    // issued even though the address does not exist yet.
    expect(write).toHaveBeenCalledTimes(1);
    const [items] = write.mock.calls[0] as unknown as [FakeClipboardItem[]];
    const item = items[0] as FakeClipboardItem;
    release('abc12345@sub-dom-1.cabalmail.com');
    const blob = (await item.items['text/plain']) as Blob;
    expect(blob.type).toBe('text/plain');
    expect(await readBlob(blob)).toBe('abc12345@sub-dom-1.cabalmail.com');
    await expect(done).resolves.toBeUndefined();
  });

  it('falls back to writeText after the payload resolves when ClipboardItem is missing', async () => {
    const writeText = vi.fn(async () => {});
    installClipboard({ writeText });

    await copyWhenReady(Promise.resolve('abc12345@sub-dom-1.cabalmail.com'));
    expect(writeText).toHaveBeenCalledWith('abc12345@sub-dom-1.cabalmail.com');
  });

  it('copies nothing when the payload rejects', async () => {
    const writeText = vi.fn(async () => {});
    installClipboard({ writeText });

    await expect(copyWhenReady(Promise.reject(new Error('409')))).rejects.toThrow('409');
    expect(writeText).not.toHaveBeenCalled();
  });

  it('surfaces a refused write', async () => {
    const writeText = vi.fn(async () => {
      throw new DOMException('denied', 'NotAllowedError');
    });
    installClipboard({ writeText });

    await expect(copyWhenReady(Promise.resolve('x'))).rejects.toThrow('denied');
  });
});

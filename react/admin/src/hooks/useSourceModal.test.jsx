import { renderHook, act, waitFor } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import useSourceModal from './useSourceModal';

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

function setup(initialFilename = 'report.xml') {
  const view = renderHook(({ name }) => useSourceModal(name), {
    initialProps: { name: initialFilename },
  });
  const load = vi.fn();
  const open = (overrides = {}) => {
    const d = deferred();
    load.mockReturnValueOnce(d.promise);
    act(() => {
      view.result.current.show({
        title: 'Org - id',
        filename: 'org-id.xml',
        load,
        ...overrides,
      });
    });
    return d;
  };
  return { ...view, load, open };
}

describe('useSourceModal', () => {
  it('starts closed and empty, offering the initial filename', () => {
    const { result } = setup('dmarc-report.xml');
    expect(result.current.modalProps).toEqual({
      open: false,
      title: '',
      filename: 'dmarc-report.xml',
      xmlText: '',
      loading: false,
      error: false,
    });
  });

  it('opens in the loading state with the row title and filename, and calls load once', () => {
    const { result, load, open } = setup();
    open();
    expect(load).toHaveBeenCalledTimes(1);
    expect(result.current.modalProps).toEqual({
      open: true,
      title: 'Org - id',
      filename: 'org-id.xml',
      xmlText: '',
      loading: true,
      error: false,
    });
  });

  it('shows the resolved text and clears loading', async () => {
    const { result, open } = setup();
    const d = open();
    await act(async () => { d.resolve({ data: '<xml/>' }); });
    await waitFor(() => expect(result.current.modalProps.loading).toBe(false));
    expect(result.current.modalProps.xmlText).toBe('<xml/>');
    expect(result.current.modalProps.error).toBe(false);
  });

  it('stringifies a non-string body and renders a missing one as empty', async () => {
    const { result, open } = setup();
    const d = open();
    await act(async () => { d.resolve({ data: { toString: () => 'OBJ' } }); });
    await waitFor(() => expect(result.current.modalProps.loading).toBe(false));
    expect(result.current.modalProps.xmlText).toBe('OBJ');

    const d2 = open();
    await act(async () => { d2.resolve({ data: null }); });
    await waitFor(() => expect(result.current.modalProps.loading).toBe(false));
    expect(result.current.modalProps.xmlText).toBe('');
  });

  it('flags a failed fetch and clears loading', async () => {
    const { result, open } = setup();
    const d = open();
    await act(async () => { d.reject(new Error('boom')); });
    await waitFor(() => expect(result.current.modalProps.loading).toBe(false));
    expect(result.current.modalProps.error).toBe(true);
    expect(result.current.modalProps.xmlText).toBe('');
  });

  it('clears the previous row text and error when the next row opens', async () => {
    const { result, open } = setup();
    const failed = open();
    await act(async () => { failed.reject(new Error('boom')); });
    await waitFor(() => expect(result.current.modalProps.error).toBe(true));

    open({ title: 'Other - 2', filename: 'other-2.xml' });
    expect(result.current.modalProps).toEqual({
      open: true,
      title: 'Other - 2',
      filename: 'other-2.xml',
      xmlText: '',
      loading: true,
      error: false,
    });
  });

  it('closes without discarding the loaded text', async () => {
    const { result, open } = setup();
    const d = open();
    await act(async () => { d.resolve({ data: 'BODY' }); });
    await waitFor(() => expect(result.current.modalProps.loading).toBe(false));

    act(() => { result.current.close(); });
    expect(result.current.modalProps.open).toBe(false);
    expect(result.current.modalProps.xmlText).toBe('BODY');
  });

  it('still applies a fetch that resolves after the modal was closed', async () => {
    const { result, open } = setup();
    const d = open();
    act(() => { result.current.close(); });
    await act(async () => { d.resolve({ data: 'LATE' }); });
    await waitFor(() => expect(result.current.modalProps.loading).toBe(false));
    expect(result.current.modalProps.open).toBe(false);
    expect(result.current.modalProps.xmlText).toBe('LATE');
  });

  it('keeps show and close referentially stable across renders', () => {
    const { result, rerender, open } = setup();
    const first = { show: result.current.show, close: result.current.close };
    open();
    rerender({ name: 'ignored-after-mount.xml' });
    expect(result.current.show).toBe(first.show);
    expect(result.current.close).toBe(first.close);
  });
});

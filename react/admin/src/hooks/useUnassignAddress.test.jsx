import { renderHook, act, waitFor } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import useUnassignAddress from './useUnassignAddress';

let unassignAddress;
let setMessage;
let onDone;

function setup(overrides = {}) {
  return renderHook(() => useUnassignAddress({
    api: { unassignAddress },
    setMessage,
    onDone,
    failureLabel: 'Failed to remove user: ',
    ...overrides,
  }));
}

describe('useUnassignAddress', () => {
  beforeEach(() => {
    unassignAddress = vi.fn().mockResolvedValue({});
    setMessage = vi.fn();
    onDone = vi.fn();
  });

  it('starts with nothing staged', () => {
    const { result } = setup();
    expect(result.current.pendingUnassign).toBeNull();
  });

  it('stages the target address first, username second', () => {
    const { result } = setup();
    act(() => { result.current.handleUnassign('a@x.cabalmail.com', 'alice'); });
    expect(result.current.pendingUnassign).toEqual({ address: 'a@x.cabalmail.com', username: 'alice' });
  });

  it('cancel drops the staged target without sending anything', () => {
    const { result } = setup();
    act(() => { result.current.handleUnassign('a@x.cabalmail.com', 'alice'); });
    act(() => { result.current.cancelUnassign(); });
    expect(result.current.pendingUnassign).toBeNull();
    expect(unassignAddress).not.toHaveBeenCalled();
  });

  it('confirm sends address then username, and clears the target first', async () => {
    const { result } = setup();
    act(() => { result.current.handleUnassign('a@x.cabalmail.com', 'alice'); });
    act(() => { result.current.confirmUnassign(); });
    expect(result.current.pendingUnassign).toBeNull();
    expect(unassignAddress).toHaveBeenCalledWith('a@x.cabalmail.com', 'alice');
    await waitFor(() => expect(onDone).toHaveBeenCalledTimes(1));
  });

  it('toasts the removal on success', async () => {
    const { result } = setup();
    act(() => { result.current.handleUnassign('a@x.cabalmail.com', 'alice'); });
    act(() => { result.current.confirmUnassign(); });
    await waitFor(() => expect(setMessage).toHaveBeenCalledWith(
      'Removed "alice" from "a@x.cabalmail.com".', false,
    ));
  });

  // The views never reach this branch — ConfirmDialog unmounts its buttons when
  // `open` is false, so there is no control left to click once the target is
  // cleared. It is pinned here because the hook exposes confirmUnassign directly.
  it('confirm with nothing staged is a no-op', () => {
    const { result } = setup();
    act(() => { result.current.confirmUnassign(); });
    expect(unassignAddress).not.toHaveBeenCalled();
    expect(setMessage).not.toHaveBeenCalled();
    expect(onDone).not.toHaveBeenCalled();
  });

  it('prefers the API error field over the transport message', async () => {
    unassignAddress = vi.fn().mockRejectedValue(Object.assign(new Error('transport said 502'), {
      response: { data: { Error: 'address is suspended' } },
    }));
    const { result } = setup();
    act(() => { result.current.handleUnassign('a@x.cabalmail.com', 'alice'); });
    act(() => { result.current.confirmUnassign(); });
    await waitFor(() => expect(setMessage).toHaveBeenCalledWith(
      'Failed to remove user: address is suspended', true,
    ));
    expect(onDone).not.toHaveBeenCalled();
  });

  it('falls back to the transport message, then to the raw rejection', async () => {
    unassignAddress = vi.fn().mockRejectedValue(new Error('network down'));
    const first = setup();
    act(() => { first.result.current.handleUnassign('a@x.cabalmail.com', 'alice'); });
    act(() => { first.result.current.confirmUnassign(); });
    await waitFor(() => expect(setMessage).toHaveBeenCalledWith(
      'Failed to remove user: network down', true,
    ));

    setMessage = vi.fn();
    unassignAddress = vi.fn().mockRejectedValue('plain string rejection');
    const second = setup();
    act(() => { second.result.current.handleUnassign('b@x.cabalmail.com', 'bob'); });
    act(() => { second.result.current.confirmUnassign(); });
    await waitFor(() => expect(setMessage).toHaveBeenCalledWith(
      'Failed to remove user: plain string rejection', true,
    ));
  });

  it('tolerates a caller with no setMessage on both outcomes', async () => {
    setMessage = undefined;
    const ok = setup({ setMessage: undefined });
    act(() => { ok.result.current.handleUnassign('a@x.cabalmail.com', 'alice'); });
    act(() => { ok.result.current.confirmUnassign(); });
    await waitFor(() => expect(onDone).toHaveBeenCalledTimes(1));

    unassignAddress = vi.fn().mockRejectedValue(new Error('network down'));
    const failed = setup({ setMessage: undefined });
    act(() => { failed.result.current.handleUnassign('a@x.cabalmail.com', 'alice'); });
    act(() => { failed.result.current.confirmUnassign(); });
    await waitFor(() => expect(unassignAddress).toHaveBeenCalledTimes(1));
    expect(onDone).toHaveBeenCalledTimes(1);
  });

  it('keeps handleUnassign and cancelUnassign referentially stable', () => {
    const { result, rerender } = setup();
    const first = { handle: result.current.handleUnassign, cancel: result.current.cancelUnassign };
    rerender();
    expect(result.current.handleUnassign).toBe(first.handle);
    expect(result.current.cancelUnassign).toBe(first.cancel);
  });
});

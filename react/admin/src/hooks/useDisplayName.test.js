import { renderHook, act, waitFor } from '@testing-library/react';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import useDisplayName from './useDisplayName';

const STORAGE_KEY = 'cabalmail.displayname.v1';

function mockApi({ name = '' } = {}) {
  return {
    getPreferences: vi.fn().mockResolvedValue({ data: { name } }),
    putPreferences: vi.fn().mockResolvedValue({}),
  };
}

describe('useDisplayName', () => {
  beforeEach(() => {
    window.localStorage.clear();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('starts from localStorage when no api client is available', () => {
    window.localStorage.setItem(STORAGE_KEY, 'Stored Name');
    const { result } = renderHook(() => useDisplayName(null));
    expect(result.current.name).toBe('Stored Name');
  });

  it('hydrates from get_preferences once a client is available', async () => {
    const api = mockApi({ name: 'Remote Name' });
    const { result } = renderHook(() => useDisplayName(api));
    await waitFor(() => expect(result.current.name).toBe('Remote Name'));
    expect(api.getPreferences).toHaveBeenCalledTimes(1);
    expect(window.localStorage.getItem(STORAGE_KEY)).toBe('Remote Name');
  });

  it('saves only the name key, debounced, after an edit', async () => {
    const api = mockApi({ name: '' });
    const { result } = renderHook(() => useDisplayName(api));
    await waitFor(() => expect(api.getPreferences).toHaveBeenCalled());

    vi.useFakeTimers();
    act(() => result.current.setName('Chris Carr'));
    expect(api.putPreferences).not.toHaveBeenCalled();
    act(() => vi.advanceTimersByTime(1100));
    expect(api.putPreferences).toHaveBeenCalledWith({ name: 'Chris Carr' });
  });

  it('strips control characters and caps length', () => {
    const { result } = renderHook(() => useDisplayName(null));
    act(() => result.current.setName('Bad\r\nName'));
    expect(result.current.name).toBe('BadName');
    act(() => result.current.setName('x'.repeat(150)));
    expect(result.current.name).toBe('x'.repeat(100));
  });

  it('does not save before hydration completes', () => {
    const api = {
      getPreferences: vi.fn(() => new Promise(() => {})),
      putPreferences: vi.fn(),
    };
    vi.useFakeTimers();
    const { result } = renderHook(() => useDisplayName(api));
    act(() => result.current.setName('Too Early'));
    act(() => vi.advanceTimersByTime(2000));
    expect(api.putPreferences).not.toHaveBeenCalled();
  });
});

import { renderHook, act, waitFor } from '@testing-library/react';
import { describe, it, expect, vi } from 'vitest';
import AppMessageContext from '../contexts/AppMessageContext';
import usePagedReports from './usePagedReports';

const sortByRank = (reports) => [...reports].sort((a, b) => Number(b.rank) - Number(a.rank));

const row = (rank) => ({ id: `r${rank}`, rank });

function setup(pages) {
  const setMessage = vi.fn();
  const fetchPage = vi.fn(() => {
    const seen = fetchPage.mock.calls.length - 1;
    const page = pages[Math.min(seen, pages.length - 1)];
    return 'reject' in page ? Promise.reject(page.reject) : Promise.resolve(page.resolve);
  });
  const wrapper = ({ children }) => (
    <AppMessageContext.Provider value={{ setMessage }}>{children}</AppMessageContext.Provider>
  );
  const view = renderHook(
    () => usePagedReports({ fetchPage, sortReports: sortByRank, errorLabel: 'CAA' }),
    { wrapper }
  );
  return { ...view, fetchPage, setMessage };
}

const page = (Reports, NextToken) => ({ resolve: { data: { Reports, NextToken } } });

describe('usePagedReports', () => {
  it('loads the first page with no token and sorts it', async () => {
    const { result, fetchPage } = setup([page([row(1), row(3), row(2)], null)]);
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(fetchPage).toHaveBeenCalledTimes(1);
    expect(fetchPage).toHaveBeenCalledWith(undefined);
    expect(result.current.reports.map((r) => r.rank)).toEqual([3, 2, 1]);
    expect(result.current.nextToken).toBe(null);
  });

  it('appends a later page and re-sorts the merged list', async () => {
    const { result, fetchPage } = setup([page([row(4), row(1)], 'tok'), page([row(3), row(9)], null)]);
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.nextToken).toBe('tok');

    act(() => result.current.loadMore());
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(fetchPage).toHaveBeenLastCalledWith('tok');
    expect(result.current.reports.map((r) => r.rank)).toEqual([9, 4, 3, 1]);
    expect(result.current.nextToken).toBe(null);
  });

  it('loadMore does nothing without a token', async () => {
    const { result, fetchPage } = setup([page([row(1)], null)]);
    await waitFor(() => expect(result.current.loading).toBe(false));
    act(() => result.current.loadMore());
    expect(fetchPage).toHaveBeenCalledTimes(1);
  });

  it('refresh drops the token and reloads from the first page', async () => {
    const { result, fetchPage } = setup([page([row(1)], 'tok'), page([row(7)], null)]);
    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => result.current.refresh());
    expect(result.current.nextToken).toBe(null);
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(fetchPage).toHaveBeenLastCalledWith(undefined);
    expect(result.current.reports.map((r) => r.rank)).toEqual([7]);
  });

  it('reports a failed page and leaves the token alone so it can be retried', async () => {
    const { result, setMessage } = setup([
      page([row(1)], 'tok'),
      { reject: new Error('page 2 down') },
    ]);
    await waitFor(() => expect(result.current.loading).toBe(false));

    act(() => result.current.loadMore());
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(setMessage).toHaveBeenCalledWith('Failed to load CAA reports: page 2 down', true);
    expect(result.current.nextToken).toBe('tok');
    expect(result.current.reports.map((r) => r.rank)).toEqual([1]);
  });

  it('falls back to the rejection value when it is not an Error', async () => {
    const { result, setMessage } = setup([{ reject: 'plain failure' }]);
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(setMessage).toHaveBeenCalledWith('Failed to load CAA reports: plain failure', true);
  });

  it('accepts an unwrapped response and a page with no Reports key', async () => {
    const { result } = setup([{ resolve: { Reports: [row(2)], NextToken: 'tok' } }, { resolve: { data: {} } }]);
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.reports.map((r) => r.rank)).toEqual([2]);

    act(() => result.current.loadMore());
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.reports.map((r) => r.rank)).toEqual([2]);
    expect(result.current.nextToken).toBe(null);
  });
});

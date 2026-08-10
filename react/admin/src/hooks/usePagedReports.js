import { useState, useEffect, useCallback } from 'react';
import { useAppMessage } from '../contexts/AppMessageContext';

/**
 * Shared token-paged report loading for the two report views (Dmarc, Caa).
 * Both back an append-as-you-page list off an API that answers
 * `{ Reports, NextToken }`: the first page replaces the list, a page fetched
 * with a token is appended, and either way the merged list is re-sorted by the
 * view's own comparator.
 *
 * `loading` starts true so the caller can render its first-load placeholder
 * before the effect fires. A failed page reports through the app message
 * banner and clears `loading`, but deliberately leaves `nextToken` alone, so
 * "Load more" stays available to retry the same page.
 *
 * @param {object} options
 * @param {Function} options.fetchPage Called with the page token (undefined
 *   for the first page); must be referentially stable (wrap in `useCallback`)
 *   or the load effect will re-fire every render.
 * @param {Function} options.sortReports Orders the merged list; also expected
 *   to be stable, so define it at module scope.
 * @param {string} options.errorLabel Report name used in the failure message.
 * @returns {{reports: Array, loading: boolean, nextToken: ?string,
 *   refresh: Function, loadMore: Function}} List state plus the two controls.
 */
export default function usePagedReports({ fetchPage, sortReports, errorLabel }) {
  const { setMessage } = useAppMessage();
  const [reports, setReports] = useState([]);
  const [loading, setLoading] = useState(true);
  const [nextToken, setNextToken] = useState(null);

  const loadReports = useCallback((token) => {
    setLoading(true);
    fetchPage(token).then(
      (response) => {
        const data = response.data || response;
        const newReports = data.Reports || [];
        if (token) {
          setReports(prev => sortReports([...prev, ...newReports]));
        } else {
          setReports(sortReports(newReports));
        }
        setNextToken(data.NextToken || null);
        setLoading(false);
      },
      (err) => {
        setMessage(`Failed to load ${errorLabel} reports: ` + (err.message || err), true);
        setLoading(false);
      }
    );
  }, [fetchPage, sortReports, errorLabel, setMessage]);

  useEffect(() => {
    loadReports();
  }, [loadReports]);

  const refresh = useCallback(() => {
    setNextToken(null);
    loadReports();
  }, [loadReports]);

  const loadMore = useCallback(() => {
    if (nextToken) {
      loadReports(nextToken);
    }
  }, [nextToken, loadReports]);

  return { reports, loading, nextToken, refresh, loadMore };
}

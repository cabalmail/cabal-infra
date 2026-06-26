/* =========================================================================
   Per-session, domain-keyed memo for BIMI logo lookups.

   `/fetch_bimi` returns the same rasterized-PNG URL (or null) for a given
   sender domain regardless of caller, so resolving a domain once per session
   is enough. The list recycles rows aggressively as it scrolls, so without a
   shared cache the same domain would round-trip the Lambda on every row that
   scrolls into view. This mirrors the Apple client's `BimiUrlCache` actor:
   concurrent lookups for the same domain coalesce onto one request, and a
   resolved result -- whether a URL or null (no record / failed lookup) -- is
   cached and never re-fetched.
   ========================================================================= */

const resolved = new Map(); // domain -> string | null
const inflight = new Map(); // domain -> Promise<string | null>

/* Synchronous peek: the cached URL/null, or undefined when not yet resolved. */
export function peekBimi(domain) {
  return resolved.has(domain) ? resolved.get(domain) : undefined;
}

/* Resolve a domain's logo URL, coalescing concurrent callers and caching the
   outcome. Always resolves (never rejects): any error -- including a missing
   getBimiUrl on the api -- becomes a cached null so the caller draws its
   initials fallback and stops asking. */
export function fetchBimi(api, domain) {
  if (!domain) return Promise.resolve(null);
  if (resolved.has(domain)) return Promise.resolve(resolved.get(domain));
  if (inflight.has(domain)) return inflight.get(domain);

  let request;
  try {
    request = api && api.getBimiUrl(domain);
  } catch (e) {
    request = Promise.reject(e);
  }
  if (!request || typeof request.then !== 'function') {
    request = Promise.reject(new Error('getBimiUrl unavailable'));
  }

  const promise = request
    .then((response) => {
      const url = (response && response.data && response.data.url) || null;
      resolved.set(domain, url);
      inflight.delete(domain);
      return url;
    })
    .catch(() => {
      resolved.set(domain, null);
      inflight.delete(domain);
      return null;
    });

  inflight.set(domain, promise);
  return promise;
}

/* Test seam: clear the module-global cache between cases. */
export function _resetBimiCache() {
  resolved.clear();
  inflight.clear();
}

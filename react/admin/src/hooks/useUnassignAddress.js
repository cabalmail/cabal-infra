import { useState, useCallback } from 'react';

/**
 * Shared "remove a user from an address" confirmation flow for the two admin
 * views that offer it (Addresses, Users). Both stage the target on the chip's
 * remove button, hang a ConfirmDialog off it, and on confirm clear the target
 * first, call `unassignAddress`, then toast and reload.
 *
 * The target is staged as `{address, username}` regardless of which view asked,
 * so `handleUnassign` always takes the address first — the Users view used to
 * take the username first and swap on the way into the request.
 *
 * `setMessage` is called through a guard because the Addresses view receives it
 * as an optional prop. The Users view reads it from `useAppMessage()`, which
 * throws without a provider, so there the guard can never be the deciding
 * factor.
 *
 * @param {object} params
 * @param {object} params.api ApiClient instance; only `unassignAddress` is used.
 * @param {Function} [params.setMessage] Toast callback `(text, isError)`.
 * @param {Function} params.onDone Reload run after a successful removal.
 * @param {string} params.failureLabel Prefix for the failure toast, including
 *   its trailing separator — the two views word this differently.
 * @returns {{pendingUnassign: ?object, handleUnassign: Function,
 *   cancelUnassign: Function, confirmUnassign: Function}} `pendingUnassign` is
 *   the staged `{address, username}` or null; `handleUnassign(address,
 *   username)` stages one; `cancelUnassign` drops it; `confirmUnassign` sends
 *   the request.
 */
export default function useUnassignAddress({ api, setMessage, onDone, failureLabel }) {
  const [pendingUnassign, setPendingUnassign] = useState(null);

  const handleUnassign = useCallback((address, username) => {
    setPendingUnassign({ address, username });
  }, []);

  const cancelUnassign = useCallback(() => {
    setPendingUnassign(null);
  }, []);

  const confirmUnassign = useCallback(() => {
    const target = pendingUnassign;
    if (!target) return;
    setPendingUnassign(null);
    const { address, username } = target;
    api.unassignAddress(address, username).then(
      () => {
        setMessage && setMessage(`Removed "${username}" from "${address}".`, false);
        onDone();
      },
      (err) => {
        const msg = err.response?.data?.Error || err.message || err;
        setMessage && setMessage(failureLabel + msg, true);
      }
    );
  }, [api, pendingUnassign, setMessage, onDone, failureLabel]);

  return { pendingUnassign, handleUnassign, cancelUnassign, confirmUnassign };
}

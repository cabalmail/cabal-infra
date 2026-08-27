import { useCallback } from 'react';

/**
 * Shared multi-select toggle for the two envelope lists (the folder view's
 * Envelopes and the Search results pane). Both hand the same callback to
 * every Envelope row, and both resolve a click the same way: a shift-click
 * extends from the last row touched to this one over the currently shown
 * order, anything else flips this row's own membership. Either way the row
 * becomes the new range anchor, and the first selection turns bulk mode on.
 *
 * Shift-extension is add-only and clamped to `shownIds`: if either end of the
 * range has scrolled out of the shown order the extension degrades to adding
 * just the clicked row, which is why the range lookup is guarded rather than
 * assumed.
 *
 * The rows pass a `meta` flag alongside `shift` (set for cmd/ctrl-click).
 * Neither list has ever branched on it -- a modified click and a plain click
 * both toggle the one row -- so it is accepted and ignored here.
 *
 * @param {object} params
 * @param {Set<number>} params.selected Currently selected message IDs.
 * @param {Function} params.setSelected Replaces the selection set.
 * @param {number[]} params.shownIds Message IDs in displayed order; the
 *   coordinate space shift-extension walks.
 * @param {{current: ?number}} params.lastSelectedRef Range anchor, updated on
 *   every toggle.
 * @param {boolean} params.bulkMode Whether the list is already in bulk mode.
 * @param {Function} params.setBulkMode Enters bulk mode on first selection.
 * @returns {Function} `toggleSelect(id, {shift})` for an Envelope row.
 */
export default function useEnvelopeSelection({
  selected,
  setSelected,
  shownIds,
  lastSelectedRef,
  bulkMode,
  setBulkMode,
}) {
  return useCallback(
    (id, { shift } = {}) => {
      const next = new Set(selected);
      if (shift && lastSelectedRef.current != null && shownIds.length) {
        const a = shownIds.indexOf(Number(lastSelectedRef.current));
        const b = shownIds.indexOf(Number(id));
        if (a !== -1 && b !== -1) {
          const [lo, hi] = a < b ? [a, b] : [b, a];
          for (let i = lo; i <= hi; i += 1) next.add(shownIds[i]);
        } else {
          next.add(Number(id));
        }
      } else {
        const num = Number(id);
        if (next.has(num)) next.delete(num);
        else next.add(num);
      }
      setSelected(next);
      lastSelectedRef.current = Number(id);
      if (!bulkMode && next.size > 0) setBulkMode(true);
    },
    [selected, setSelected, shownIds, lastSelectedRef, bulkMode, setBulkMode],
  );
}

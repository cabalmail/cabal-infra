/**
 * Tooltip for an envelope row's leading cell.
 *
 * The cell holds the unread dot, and in bulk mode a selection checkbox
 * beside it. Bulk mode used to replace the whole cell's `Unread`/`Read`
 * with `Select message`, which took away the hover fallback for read state
 * at exactly the moment the dot was hidden too. Both now survive.
 *
 * @param {boolean} bulkMode Whether the list is in bulk-selection mode.
 * @param {boolean} unread Whether the message is unread.
 * @returns {string} The title attribute for the leading cell.
 */
export default function leadingTitle(bulkMode, unread) {
  const state = unread ? 'Unread' : 'Read';
  return bulkMode ? `Select message (${state})` : state;
}

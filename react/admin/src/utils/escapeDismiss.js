/**
 * Which layer an Escape keypress should dismiss in the Email view.
 *
 * Two dismissable layers stack there: the message reader overlay and any
 * number of compose windows. A composer is opened over the reader and paints
 * above it, so Escape has to take the composer first — closing the reader out
 * from under an open composer loses the user's place in the message while
 * leaving the composer exactly where it was.
 *
 * The decision is pure so the ordering can be tested without mounting the
 * whole view; the caller does the dismissing.
 *
 * @param {object} state Current layer state.
 * @param {boolean} state.overlayVisible Whether the reader overlay is open.
 * @param {Array<{id: number}>} state.composeWindows Compose windows, oldest first.
 * @returns {{kind: string, id: number}|{kind: string}|null} The topmost
 *   dismissable layer, or null when there is nothing to dismiss.
 */
export default function topmostDismissal({ overlayVisible, composeWindows }) {
  const windows = composeWindows || [];
  if (windows.length > 0) {
    return { kind: 'compose', id: windows[windows.length - 1].id };
  }
  if (overlayVisible) return { kind: 'reader' };
  return null;
}

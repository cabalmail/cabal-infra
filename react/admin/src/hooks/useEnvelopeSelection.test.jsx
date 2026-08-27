import { useState, useRef } from 'react';
import { renderHook, act } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import useEnvelopeSelection from './useEnvelopeSelection';

const SHOWN = [10, 20, 30, 40, 50];

// The two lists own the selection state and the range anchor and hand them to
// the hook, so the harness owns them here too.
function setup(shownIds = SHOWN, initial = []) {
  return renderHook(() => {
    const [selected, setSelected] = useState(() => new Set(initial));
    const [bulkMode, setBulkMode] = useState(false);
    const lastSelectedRef = useRef(null);
    const toggleSelect = useEnvelopeSelection({
      selected,
      setSelected,
      shownIds,
      lastSelectedRef,
      bulkMode,
      setBulkMode,
    });
    return { toggleSelect, selected, bulkMode, lastSelectedRef };
  });
}

const ids = (result) => [...result.current.selected];

describe('useEnvelopeSelection', () => {
  it('adds a row on a plain click and removes it on the next one', () => {
    const { result } = setup();
    act(() => result.current.toggleSelect('30'));
    expect(ids(result)).toEqual([30]);

    act(() => result.current.toggleSelect('30'));
    expect(ids(result)).toEqual([]);
  });

  it('extends forward from the anchor to the clicked row', () => {
    const { result } = setup();
    act(() => result.current.toggleSelect('20'));
    act(() => result.current.toggleSelect('40', { shift: true }));
    expect(ids(result)).toEqual([20, 30, 40]);
  });

  it('extends backward when the clicked row precedes the anchor', () => {
    const { result } = setup();
    act(() => result.current.toggleSelect('40'));
    act(() => result.current.toggleSelect('20', { shift: true }));
    expect(ids(result)).toEqual([40, 20, 30]);
  });

  it('extends by adding only, so a shift range never clears a selected row', () => {
    const { result } = setup(SHOWN, [30]);
    act(() => result.current.toggleSelect('10'));
    act(() => result.current.toggleSelect('30', { shift: true }));
    expect(ids(result)).toEqual([30, 10, 20]);
  });

  it('falls back to the clicked row when an end of the range is not shown', () => {
    const { result } = setup();
    act(() => result.current.toggleSelect('99'));
    act(() => result.current.toggleSelect('20', { shift: true }));
    expect(ids(result)).toEqual([99, 20]);
  });

  it('toggles instead of extending when nothing is shown', () => {
    const { result } = setup([]);
    act(() => result.current.toggleSelect('10'));
    act(() => result.current.toggleSelect('10', { shift: true }));
    expect(ids(result)).toEqual([]);
  });

  it('toggles instead of extending when there is no anchor yet', () => {
    const { result } = setup();
    act(() => result.current.toggleSelect('30', { shift: true }));
    expect(ids(result)).toEqual([30]);
  });

  it('treats a modified click the same as a plain one', () => {
    const { result } = setup();
    act(() => result.current.toggleSelect('30', { meta: true }));
    expect(ids(result)).toEqual([30]);

    act(() => result.current.toggleSelect('30', { meta: true }));
    expect(ids(result)).toEqual([]);
  });

  it('stores the clicked row as the next anchor, coerced to a number', () => {
    const { result } = setup();
    act(() => result.current.toggleSelect('40', { shift: true }));
    expect(result.current.lastSelectedRef.current).toBe(40);
  });

  it('enters bulk mode on the first selection and not on an empty one', () => {
    const { result } = setup();
    expect(result.current.bulkMode).toBe(false);

    act(() => result.current.toggleSelect('30'));
    expect(result.current.bulkMode).toBe(true);

    act(() => result.current.toggleSelect('30'));
    expect(ids(result)).toEqual([]);
    expect(result.current.bulkMode).toBe(true);
  });

  it('keeps the callback stable across a render that changes none of its inputs', () => {
    const { result, rerender } = setup();
    const first = result.current.toggleSelect;
    rerender();
    expect(result.current.toggleSelect).toBe(first);
  });
});

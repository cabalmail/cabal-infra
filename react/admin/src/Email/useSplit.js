import { useCallback, useEffect, useRef, useState } from 'react';

export default function useSplit({ storageKey, defaultPct, min, max, axis, anchor = 'start' }) {
  const [pct, setPct] = useState(() => {
    try {
      const raw = localStorage.getItem(storageKey);
      const v = parseFloat(raw);
      if (Number.isFinite(v) && v >= min && v <= max) return v;
    } catch (e) { /* ignore */ }
    return defaultPct;
  });
  const containerRef = useRef(null);
  const dragging = useRef(false);

  useEffect(() => {
    try { localStorage.setItem(storageKey, String(pct)); } catch (e) { /* ignore */ }
  }, [pct, storageKey]);

  useEffect(() => () => {
    document.body.style.cursor = '';
    document.body.style.userSelect = '';
  }, []);

  const cursor = axis === 'y' ? 'row-resize' : 'col-resize';

  const onPointerMove = useCallback((e) => {
    if (!dragging.current || !containerRef.current) return;
    const rect = containerRef.current.getBoundingClientRect();
    const total = axis === 'y' ? rect.height : rect.width;
    if (total <= 0) return;
    const pos = axis === 'y' ? e.clientY - rect.top : e.clientX - rect.left;
    // `anchor: 'end'` panels (e.g. a right sidebar) measure their size from
    // the container's trailing edge, so pct tracks the pane's own width.
    const offset = anchor === 'end' ? total - pos : pos;
    const next = (offset / total) * 100;
    setPct(Math.min(max, Math.max(min, next)));
  }, [axis, min, max, anchor]);

  const stop = useCallback(() => {
    if (!dragging.current) return;
    dragging.current = false;
    document.body.style.cursor = '';
    document.body.style.userSelect = '';
    window.removeEventListener('pointermove', onPointerMove);
    window.removeEventListener('pointerup', stop);
    window.removeEventListener('pointercancel', stop);
  }, [onPointerMove]);

  const onPointerDown = useCallback((e) => {
    if (e.button !== undefined && e.button !== 0) return;
    e.preventDefault();
    dragging.current = true;
    document.body.style.cursor = cursor;
    document.body.style.userSelect = 'none';
    window.addEventListener('pointermove', onPointerMove);
    window.addEventListener('pointerup', stop);
    window.addEventListener('pointercancel', stop);
  }, [cursor, onPointerMove, stop]);

  const reset = useCallback(() => setPct(defaultPct), [defaultPct]);

  const onKeyDown = useCallback((e) => {
    // For an `end`-anchored horizontal pane, ArrowLeft grows it (the divider
    // moves left, the pane widens), so the inc/dec keys are swapped.
    const horizDec = anchor === 'end' ? 'ArrowRight' : 'ArrowLeft';
    const horizInc = anchor === 'end' ? 'ArrowLeft' : 'ArrowRight';
    const decKey = axis === 'y' ? 'ArrowUp' : horizDec;
    const incKey = axis === 'y' ? 'ArrowDown' : horizInc;
    if (e.key === decKey) {
      e.preventDefault();
      setPct((p) => Math.max(min, p - 2));
    } else if (e.key === incKey) {
      e.preventDefault();
      setPct((p) => Math.min(max, p + 2));
    } else if (e.key === 'Home') {
      e.preventDefault();
      setPct(min);
    } else if (e.key === 'End') {
      e.preventDefault();
      setPct(max);
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      reset();
    }
  }, [axis, min, max, reset, anchor]);

  return { pct, containerRef, onPointerDown, onKeyDown, reset, min, max };
}

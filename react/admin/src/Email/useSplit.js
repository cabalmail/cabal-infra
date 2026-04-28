import { useCallback, useEffect, useRef, useState } from 'react';

export default function useSplit({ storageKey, defaultPct, min, max, axis }) {
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
    const offset = axis === 'y' ? e.clientY - rect.top : e.clientX - rect.left;
    const next = (offset / total) * 100;
    setPct(Math.min(max, Math.max(min, next)));
  }, [axis, min, max]);

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
    const decKey = axis === 'y' ? 'ArrowUp' : 'ArrowLeft';
    const incKey = axis === 'y' ? 'ArrowDown' : 'ArrowRight';
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
  }, [axis, min, max, reset]);

  return { pct, containerRef, onPointerDown, onKeyDown, reset, min, max };
}

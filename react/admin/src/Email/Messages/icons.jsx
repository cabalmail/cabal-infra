/* =========================================================================
   Minimal icon set for the Phase 3 message list. Kept in-house until
   Preflight question (1) lands on Lucide. Stroked paths on a 22×22 grid
   at 1.5px so they match the glyphs baked into the Nav wordmark.
   ========================================================================= */

import React from 'react';

const PATHS = {
  paperclip: <path d="M16 8l-7 7a3 3 0 0 1-4.2-4.2L12 3.6a5 5 0 0 1 7 7L12 18" />,
  star: <path d="M11 3l2.5 5.2 5.5.8-4 4 1 5.5-5-2.7-5 2.7 1-5.5-4-4 5.5-.8L11 3z" />,
  'star-fill': (
    <path
      d="M11 3l2.5 5.2 5.5.8-4 4 1 5.5-5-2.7-5 2.7 1-5.5-4-4 5.5-.8L11 3z"
      fill="currentColor"
    />
  ),
  reply: <path d="M10 6L4 11l6 5M4 11h9a5 5 0 0 1 5 5" />,
  check: <path d="M5 11l4 4 8-8" />,
  'chevron-down': <path d="M6 8l5 5 5-5" />,
  flag: <path d="M5 3v17M5 4l11 2-3 4 3 4-11 2" />,
  'flag-fill': <path d="M5 3v17M5 4l11 2-3 4 3 4-11 2z" fill="currentColor" />,
  archive: (
    <>
      <rect x="3" y="5" width="16" height="3" rx="1" />
      <path d="M5 8v10a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V8" />
      <path d="M9 11l2 2 2-2" />
    </>
  ),
  trash: <path d="M4 6h14M9 6V4h4v2M6 6l1 13h8l1-13M10 10v6M12 10v6" />,
  'mark-read': (
    <>
      <path d="M3 7l8 5 8-5" />
      <rect x="3" y="5" width="16" height="13" rx="2" />
    </>
  ),
  'mark-unread': (
    <>
      <path d="M3 7l8 5 8-5" />
      <rect x="3" y="5" width="16" height="13" rx="2" />
      <circle cx="18" cy="6" r="3" fill="currentColor" stroke="none" />
    </>
  ),
  move: <path d="M3 7v9a1 1 0 0 0 1 1h13V8h-7l-2-2H4a1 1 0 0 0-1 1zM12 12h7M16 9l3 3-3 3" />,
  close: <path d="M5 5l12 12M17 5L5 17" />,
  important: (
    <>
      <path d="M11 3v10" />
      <circle cx="11" cy="17" r="1" fill="currentColor" />
    </>
  ),
};

function Icon({ name, size = 16, className = '' }) {
  const path = PATHS[name];
  if (!path) return null;
  return (
    <svg
      className={`icon icon-${name} ${className}`}
      width={size}
      height={size}
      viewBox="0 0 22 22"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {path}
    </svg>
  );
}

export default Icon;

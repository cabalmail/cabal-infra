/* Phase 8 — viewport tests for Messages phone header controls. */

import React from 'react';
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Messages from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';
import { DATE, DESC } from '../../constants';
import { setViewport, PHONE, TABLET, DESKTOP } from '../../test/viewport';

const mockGetMessages = vi.fn();
const mockApi = {
  getMessages: mockGetMessages,
  setFlag: vi.fn(),
  moveMessages: vi.fn(),
  getEnvelopes: vi.fn().mockResolvedValue({ data: { envelopes: {} } }),
  getFolderList: vi.fn().mockResolvedValue({ data: { folders: [], sub_folders: [] } }),
};

vi.mock('../../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };

function Harness({ layout, onOpenDrawer = vi.fn(), onCompose = vi.fn() }) {
  const [filter, setFilter] = React.useState('all');
  const [sortKey, setSortKey] = React.useState(DATE);
  const [sortDir, setSortDir] = React.useState(DESC);
  const [bulkMode, setBulkMode] = React.useState(false);
  const [selected, setSelected] = React.useState(() => new Set());
  return (
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage: vi.fn() }}>
        <Messages
          folder="INBOX"
          host="host"
          showOverlay={vi.fn()}
          setFolder={vi.fn()}
          setMessage={vi.fn()}
          filter={filter}
          setFilter={setFilter}
          sortKey={sortKey}
          setSortKey={setSortKey}
          sortDir={sortDir}
          setSortDir={setSortDir}
          bulkMode={bulkMode}
          setBulkMode={setBulkMode}
          selected={selected}
          setSelected={setSelected}
          layout={layout}
          onOpenDrawer={onOpenDrawer}
          onCompose={onCompose}
        />
      </AppMessageContext.Provider>
    </AuthContext.Provider>
  );
}

describe('Messages header (viewport)', () => {
  beforeEach(() => {
    mockGetMessages.mockResolvedValue({ data: { message_ids: [] } });
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('shows back + compose buttons on phone', async () => {
    setViewport(...PHONE);
    const { container, unmount } = render(<Harness layout="phone" />);
    try {
      await waitFor(() => expect(container.querySelector('.msglist-title')).toBeTruthy());
      expect(screen.getByRole('button', { name: 'Open navigation' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'New message' })).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('shows back but not compose on tablet', async () => {
    setViewport(...TABLET);
    const { container, unmount } = render(<Harness layout="tablet" />);
    try {
      await waitFor(() => expect(container.querySelector('.msglist-title')).toBeTruthy());
      expect(screen.getByRole('button', { name: 'Open navigation' })).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: 'New message' })).not.toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('shows neither back nor compose on desktop', async () => {
    setViewport(...DESKTOP);
    const { container, unmount } = render(<Harness layout="desktop" />);
    try {
      await waitFor(() => expect(container.querySelector('.msglist-title')).toBeTruthy());
      expect(screen.queryByRole('button', { name: 'Open navigation' })).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: 'New message' })).not.toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('phone back button calls onOpenDrawer', async () => {
    setViewport(...PHONE);
    const onOpenDrawer = vi.fn();
    const { container, unmount } = render(<Harness layout="phone" onOpenDrawer={onOpenDrawer} />);
    try {
      await waitFor(() => expect(container.querySelector('.msglist-title')).toBeTruthy());
      fireEvent.click(screen.getByRole('button', { name: 'Open navigation' }));
      expect(onOpenDrawer).toHaveBeenCalledTimes(1);
    } finally {
      unmount();
    }
  });

  it('phone compose button calls onCompose', async () => {
    setViewport(...PHONE);
    const onCompose = vi.fn();
    const { container, unmount } = render(<Harness layout="phone" onCompose={onCompose} />);
    try {
      await waitFor(() => expect(container.querySelector('.msglist-title')).toBeTruthy());
      fireEvent.click(screen.getByRole('button', { name: 'New message' }));
      expect(onCompose).toHaveBeenCalledTimes(1);
    } finally {
      unmount();
    }
  });

  it('renders shimmer skeleton while loading', async () => {
    setViewport(...PHONE);
    mockGetMessages.mockImplementation(() => new Promise(() => {})); // never resolves
    const { container, unmount } = render(<Harness layout="phone" />);
    try {
      expect(container.querySelector('.msglist-skel')).toBeTruthy();
      const rows = container.querySelectorAll('.msglist-skel-row');
      expect(rows.length).toBe(4);
    } finally {
      unmount();
    }
  });
});

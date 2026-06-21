import React from 'react';
import { render, screen, waitFor, act, fireEvent, within } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Messages from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';
import { DATE, DESC, MAX_BULK_IDS, BULK_CHUNK_SIZE } from '../../constants';

const mockGetMessages = vi.fn();
const mockGetFolderStatus = vi.fn();
const mockSetFlag = vi.fn();
const mockMoveMessages = vi.fn();
const mockPurgeMessages = vi.fn();
const mockGetEnvelopes = vi.fn().mockResolvedValue({ data: { envelopes: {} } });
const mockGetFolderList = vi.fn().mockResolvedValue({ data: { folders: [], sub_folders: [] } });

const mockApi = {
  getMessages: mockGetMessages,
  getFolderStatus: mockGetFolderStatus,
  setFlag: mockSetFlag,
  moveMessages: mockMoveMessages,
  purgeMessages: mockPurgeMessages,
  getEnvelopes: mockGetEnvelopes,
  getFolderList: mockGetFolderList,
};

// A STATUS reply with nothing pending: used as the default so the steady-state
// poll never re-pulls the UID list unless a test says the folder changed.
const STATUS_IDLE = { messages: 3, unseen: 1, flagged: 0, uid_validity: 1, uid_next: 10 };

vi.mock('../../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };

function Harness({ folder = 'INBOX', addressFilter = null, overrides = {} }) {
  const [filter, setFilter] = React.useState('all');
  const [sortKey, setSortKey] = React.useState(DATE);
  const [sortDir, setSortDir] = React.useState(DESC);
  const [bulkMode, setBulkMode] = React.useState(false);
  const [selected, setSelected] = React.useState(() => new Set());
  // Stable across renders, like the real app's useCallback setMessage. The
  // polling effect depends on it, so a fresh spy each render would tear the
  // effect down and re-pull the UID list on every poll-driven re-render.
  const [setMessage] = React.useState(() => vi.fn());
  return (
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage }}>
        <Messages
          folder={folder}
          host="host"
          showOverlay={vi.fn()}
          setFolder={vi.fn()}
          setMessage={setMessage}
          addressFilter={addressFilter}
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
          {...overrides}
        />
      </AppMessageContext.Provider>
    </AuthContext.Provider>
  );
}

describe('Messages', () => {
  beforeEach(() => {
    mockGetMessages.mockResolvedValue({ data: { message_ids: [1, 2, 3], total: 3 } });
    mockGetFolderStatus.mockResolvedValue({ data: STATUS_IDLE });
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('shows loading state initially', async () => {
    const { container, unmount } = render(<Harness />);
    expect(container.querySelector('.msglist-loading')).toBeTruthy();
    await act(async () => { await Promise.resolve(); });
    unmount();
  });

  it('renders the folder title and filter pills', async () => {
    const { container, unmount } = render(<Harness folder="INBOX" />);
    await waitFor(() => {
      expect(container.querySelector('.msglist-title').textContent).toBe('INBOX');
    });
    const pills = container.querySelectorAll('.msglist-tab');
    expect(pills.length).toBe(3);
    expect(Array.from(pills).map((p) => p.textContent)).toEqual(
      expect.arrayContaining([expect.stringContaining('All')]),
    );
    unmount();
  });

  it('uses the address as the title when addressFilter is set', async () => {
    const { container, unmount } = render(
      <Harness folder="INBOX" addressFilter="me@example.com" />,
    );
    await waitFor(() => {
      expect(container.querySelector('.msglist-title').textContent).toBe('me@example.com');
    });
    unmount();
  });

  it('fetches messages with the default sort and switches folders', async () => {
    const { container, unmount, rerender } = render(<Harness folder="INBOX" />);
    try {
      await waitFor(() => {
        expect(mockGetMessages).toHaveBeenCalledWith('INBOX', 'REVERSE ', 'DATE');
      });
      mockGetMessages.mockClear();

      rerender(<Harness folder="Archive" />);

      await waitFor(() => {
        expect(mockGetMessages).toHaveBeenCalledWith('Archive', 'REVERSE ', 'DATE');
      });
    } finally {
      unmount();
    }
  });

  it('shows error message when fetch fails', async () => {
    mockGetMessages.mockRejectedValueOnce(new Error('Network error'));
    mockGetMessages.mockResolvedValue({ data: { message_ids: [] } });

    const setMessage = vi.fn();
    const CaptureHarness = () => {
      const [filter, setFilter] = React.useState('all');
      const [sortKey, setSortKey] = React.useState(DATE);
      const [sortDir, setSortDir] = React.useState(DESC);
      const [bulkMode, setBulkMode] = React.useState(false);
      const [selected, setSelected] = React.useState(() => new Set());
      return (
        <AuthContext.Provider value={authValue}>
          <AppMessageContext.Provider value={{ setMessage }}>
            <Messages
              folder="INBOX"
              host="host"
              showOverlay={vi.fn()}
              setFolder={vi.fn()}
              setMessage={setMessage}
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
            />
          </AppMessageContext.Provider>
        </AuthContext.Provider>
      );
    };

    const { unmount } = render(<CaptureHarness />);
    try {
      await waitFor(() => {
        expect(setMessage).toHaveBeenCalledWith('Unable to get list of messages.', true);
      });
    } finally {
      unmount();
    }
  });

  it('filter pills switch the active filter', async () => {
    const { container, unmount } = render(<Harness />);
    try {
      await waitFor(() => {
        expect(container.querySelector('.msglist-tab')).toBeTruthy();
      });
      const tabs = container.querySelectorAll('.msglist-tab');
      expect(tabs[0].classList.contains('active')).toBe(true);
      fireEvent.click(tabs[1]);
      expect(container.querySelectorAll('.msglist-tab')[1].classList.contains('active')).toBe(true);
    } finally {
      unmount();
    }
  });

  it('toggles bulk mode when clicking Select', async () => {
    const { container, unmount } = render(<Harness />);
    try {
      await waitFor(() => {
        expect(container.querySelector('.msglist-select-toggle')).toBeTruthy();
      });
      const btn = container.querySelector('.msglist-select-toggle');
      fireEvent.click(btn);
      expect(container.querySelector('.msglist')?.classList.contains('select-mode')).toBe(true);
      // Bulk header replaces the regular one.
      expect(container.querySelector('.msglist-header.bulk')).toBeTruthy();
    } finally {
      unmount();
    }
  });

  it('refuses a bulk action above the per-request cap and warns instead', async () => {
    const tooMany = new Set(Array.from({ length: MAX_BULK_IDS + 1 }, (_, i) => i + 1));
    const setMessage = vi.fn();
    const { unmount } = render(
      <Harness folder="INBOX" overrides={{ bulkMode: true, selected: tooMany, setMessage }} />,
    );
    try {
      await waitFor(() => {
        expect(screen.getByRole('button', { name: /^delete$/i })).toBeInTheDocument();
      });
      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /^delete$/i }));
      });
      // No request is fired and no purge dialog opens; the user is told why.
      expect(mockMoveMessages).not.toHaveBeenCalled();
      expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
      expect(setMessage).toHaveBeenCalledWith(
        expect.stringContaining(MAX_BULK_IDS.toLocaleString()),
        true,
      );
    } finally {
      unmount();
    }
  });

  it('renders server-sourced counts in the filter pills', async () => {
    mockGetMessages.mockResolvedValue({ data: { message_ids: [1, 2, 3], total: 1234 } });
    mockGetFolderStatus.mockResolvedValue({
      data: { ...STATUS_IDLE, unseen: 47, flagged: 9 },
    });
    const { container, unmount } = render(<Harness />);
    try {
      // All comes from /list_messages total; Unread/Flagged from STATUS.
      await waitFor(() => {
        expect(container.querySelectorAll('.msglist-tab-count').length).toBe(3);
      });
      const counts = Array.from(container.querySelectorAll('.msglist-tab-count')).map(
        (c) => c.textContent,
      );
      expect(counts).toEqual(['1,234', '47', '9']);
    } finally {
      unmount();
    }
  });

  it('polls folder_status and re-pulls the UID list only when it changes', async () => {
    vi.useFakeTimers();
    try {
      mockGetFolderStatus
        .mockResolvedValueOnce({ data: { ...STATUS_IDLE, uid_next: 10, messages: 3 } }) // seed
        .mockResolvedValueOnce({ data: { ...STATUS_IDLE, uid_next: 10, messages: 3 } }) // unchanged
        .mockResolvedValue({ data: { ...STATUS_IDLE, uid_next: 11, messages: 4 } }); // arrival

      render(<Harness />);
      // Mount: one UID-list pull + one STATUS seed.
      await act(async () => { await vi.advanceTimersByTimeAsync(0); });
      expect(mockGetMessages).toHaveBeenCalledTimes(1);
      expect(mockGetFolderStatus).toHaveBeenCalledTimes(1);

      // A poll with unchanged UIDNEXT/MESSAGES must not re-pull the UID list.
      await act(async () => { await vi.advanceTimersByTimeAsync(10000); });
      expect(mockGetFolderStatus).toHaveBeenCalledTimes(2);
      expect(mockGetMessages).toHaveBeenCalledTimes(1);

      // A poll showing UIDNEXT advanced re-pulls the UID list.
      await act(async () => { await vi.advanceTimersByTimeAsync(10000); });
      expect(mockGetFolderStatus).toHaveBeenCalledTimes(3);
      expect(mockGetMessages).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it('clears the previous folder pill counts during a folder switch', async () => {
    mockGetMessages.mockResolvedValue({ data: { message_ids: [1, 2, 3], total: 1234 } });
    mockGetFolderStatus.mockResolvedValue({ data: { ...STATUS_IDLE, unseen: 47, flagged: 9 } });
    const { container, rerender, unmount } = render(<Harness folder="INBOX" />);
    try {
      await waitFor(() => {
        expect(
          Array.from(container.querySelectorAll('.msglist-tab-count')).map((c) => c.textContent),
        ).toEqual(['1,234', '47', '9']);
      });

      // The new folder's responses hang so we can observe the switch mid-flight.
      let resolveStatus;
      mockGetMessages.mockReturnValue(new Promise(() => {}));
      mockGetFolderStatus.mockReturnValue(new Promise((res) => { resolveStatus = res; }));
      rerender(<Harness folder="Archive" />);

      // INBOX's 1,234 / 47 / 9 must be gone immediately, not linger through the
      // (potentially seconds-long) round trip on the new folder.
      await waitFor(() => {
        expect(container.querySelectorAll('.msglist-tab-count').length).toBe(0);
      });

      resolveStatus({ data: { ...STATUS_IDLE, unseen: 2, flagged: 0 } });
    } finally {
      unmount();
    }
  });
});

describe('Messages - deleting from Trash', () => {
  beforeEach(() => {
    mockGetMessages.mockResolvedValue({ data: { message_ids: [1, 2, 3], total: 3 } });
    mockGetFolderStatus.mockResolvedValue({ data: STATUS_IDLE });
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  function renderTrashBulk() {
    return render(
      <Harness
        folder="Trash"
        overrides={{ bulkMode: true, selected: new Set([1, 2]) }}
      />,
    );
  }

  it('labels the bulk delete action "Delete forever" in Trash', async () => {
    const { unmount } = renderTrashBulk();
    try {
      await waitFor(() => {
        expect(screen.getByRole('button', { name: /delete forever/i })).toBeInTheDocument();
      });
    } finally {
      unmount();
    }
  });

  it('asks for confirmation, then purges instead of moving', async () => {
    mockPurgeMessages.mockResolvedValue({ data: { status: 'purged' } });
    const { unmount } = renderTrashBulk();
    try {
      await waitFor(() => {
        expect(screen.getByRole('button', { name: /delete forever/i })).toBeInTheDocument();
      });
      fireEvent.click(screen.getByRole('button', { name: /delete forever/i }));
      // Nothing happens until the dialog is confirmed.
      expect(mockPurgeMessages).not.toHaveBeenCalled();
      expect(mockMoveMessages).not.toHaveBeenCalled();
      const dialog = screen.getByRole('alertdialog');
      await act(async () => {
        fireEvent.click(within(dialog).getByRole('button', { name: /delete forever/i }));
      });
      expect(mockPurgeMessages).toHaveBeenCalledWith('Trash', [1, 2]);
      expect(mockMoveMessages).not.toHaveBeenCalled();
    } finally {
      unmount();
    }
  });

  it('does nothing when the confirmation is cancelled', async () => {
    const { unmount } = renderTrashBulk();
    try {
      await waitFor(() => {
        expect(screen.getByRole('button', { name: /delete forever/i })).toBeInTheDocument();
      });
      fireEvent.click(screen.getByRole('button', { name: /delete forever/i }));
      const dialog = screen.getByRole('alertdialog');
      fireEvent.click(within(dialog).getByRole('button', { name: /cancel/i }));
      expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
      expect(mockPurgeMessages).not.toHaveBeenCalled();
    } finally {
      unmount();
    }
  });

  it('outside Trash, delete still moves to Trash without confirmation', async () => {
    mockMoveMessages.mockResolvedValue({ data: { status: 'submitted' } });
    const { unmount } = render(
      <Harness folder="INBOX" overrides={{ bulkMode: true, selected: new Set([3]) }} />,
    );
    try {
      await waitFor(() => {
        expect(screen.getByRole('button', { name: /^delete$/i })).toBeInTheDocument();
      });
      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /^delete$/i }));
      });
      expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
      expect(mockMoveMessages).toHaveBeenCalledWith(
        'INBOX', 'Trash', [3], 'REVERSE ', 'DATE',
      );
      expect(mockPurgeMessages).not.toHaveBeenCalled();
    } finally {
      unmount();
    }
  });
});

// Drain micro- and macro-tasks so a chunked bulk op's sequential awaits and the
// follow-on STATUS reconcile all settle inside act().
const flush = () => act(async () => { await new Promise((r) => setTimeout(r, 0)); });

function makeEnvelope(id, overrides = {}) {
  return {
    id: id.toString(),
    from: [`Sender ${id} <sender${id}@test.com>`],
    to: ['recipient@test.com'],
    cc: [],
    subject: `Subject ${id}`,
    date: new Date().toISOString(),
    flags: [],
    priority: '',
    struct: ['alternative', 'alternative'],
    ...overrides,
  };
}

describe('Messages - optimistic bulk operations', () => {
  beforeEach(() => {
    mockGetMessages.mockResolvedValue({ data: { message_ids: [1, 2, 3], total: 3 } });
    mockGetFolderStatus.mockResolvedValue({ data: STATUS_IDLE });
    // Return whatever ids a page requests so rows actually render.
    mockGetEnvelopes.mockImplementation((folder, ids) => {
      const envelopes = {};
      ids.forEach((id) => { envelopes[id.toString()] = makeEnvelope(id); });
      return Promise.resolve({ data: { envelopes } });
    });
    mockMoveMessages.mockResolvedValue({ data: { status: 'submitted' } });
    mockSetFlag.mockResolvedValue({ data: { status: 'submitted' } });
  });

  afterEach(() => {
    vi.clearAllMocks();
    mockGetEnvelopes.mockResolvedValue({ data: { envelopes: {} } });
  });

  it('chunks a large bulk archive into BULK_CHUNK_SIZE-sized requests', async () => {
    const all = Array.from({ length: 300 }, (_, i) => i + 1);
    mockGetMessages.mockResolvedValue({ data: { message_ids: all, total: 300 } });
    const { unmount } = render(
      <Harness folder="INBOX" overrides={{ bulkMode: true, selected: new Set(all) }} />,
    );
    try {
      await waitFor(() => {
        expect(screen.getByRole('button', { name: /archive/i })).toBeInTheDocument();
      });
      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /archive/i }));
      });
      await flush();

      // 300 / 250 -> two requests: 250 then 50, every id exactly once, in order.
      expect(mockMoveMessages).toHaveBeenCalledTimes(2);
      const [, , firstChunk] = mockMoveMessages.mock.calls[0];
      const [, , secondChunk] = mockMoveMessages.mock.calls[1];
      expect(firstChunk.length).toBe(BULK_CHUNK_SIZE);
      expect(secondChunk.length).toBe(300 - BULK_CHUNK_SIZE);
      expect([...firstChunk, ...secondChunk]).toEqual(all);
    } finally {
      unmount();
    }
  });

  it('removes rows immediately and reconciles via STATUS, never re-pulling the list', async () => {
    const { container, unmount } = render(
      <Harness folder="INBOX" overrides={{ bulkMode: true, selected: new Set([2]) }} />,
    );
    try {
      await waitFor(() => {
        expect(container.querySelectorAll('.envelope-row').length).toBe(3);
      });
      mockGetMessages.mockClear();
      const statusCallsBefore = mockGetFolderStatus.mock.calls.length;

      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /archive/i }));
      });
      await flush();

      // The archived row is gone from the list...
      expect(container.querySelectorAll('.envelope-row').length).toBe(2);
      // ...the whole UID list was never re-pulled...
      expect(mockGetMessages).not.toHaveBeenCalled();
      // ...and counts were reconciled off a fresh STATUS instead.
      expect(mockGetFolderStatus.mock.calls.length).toBeGreaterThan(statusCallsBefore);
    } finally {
      unmount();
    }
  });

  it('rolls the rows back when a chunk fails', async () => {
    mockMoveMessages.mockRejectedValueOnce(new Error('boom'));
    const setMessage = vi.fn();
    const { container, unmount } = render(
      <Harness
        folder="INBOX"
        overrides={{ bulkMode: true, selected: new Set([2]), setMessage }}
      />,
    );
    try {
      await waitFor(() => {
        expect(container.querySelectorAll('.envelope-row').length).toBe(3);
      });
      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /archive/i }));
      });
      await flush();

      // The optimistic removal is undone and the user is told.
      expect(container.querySelectorAll('.envelope-row').length).toBe(3);
      expect(setMessage).toHaveBeenCalledWith('Unable to archive selected messages.', true);
    } finally {
      unmount();
    }
  });

  it('shows progress and disables the toolbar while a chunk is in flight', async () => {
    let resolveMove;
    mockMoveMessages.mockImplementationOnce(
      () => new Promise((res) => { resolveMove = res; }),
    );
    const { container, unmount } = render(
      <Harness folder="INBOX" overrides={{ bulkMode: true, selected: new Set([1, 2]) }} />,
    );
    try {
      await waitFor(() => {
        expect(screen.getByRole('button', { name: /archive/i })).toBeInTheDocument();
      });
      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /archive/i }));
      });

      // Mid-op: the count slot reads the progress, the bar is shown, and the
      // action buttons are disabled (footprint unchanged, nothing to mis-click).
      const progress = container.querySelector('.msglist-bulk-progress');
      expect(progress).toBeTruthy();
      expect(progress.textContent).toContain('Archiving');
      expect(progress.textContent).toContain('of 2');
      expect(container.querySelector('.msglist-bulk-progressbar')).toBeTruthy();
      expect(screen.getByRole('button', { name: /archive/i })).toBeDisabled();

      await act(async () => {
        resolveMove({ data: { status: 'submitted' } });
        await new Promise((r) => setTimeout(r, 0));
      });
      // The progress affordance clears once the op settles.
      expect(container.querySelector('.msglist-bulk-progress')).toBeFalsy();
    } finally {
      unmount();
    }
  });

  it('bulk mark-read chunks set_flag and reconciles without re-pulling the list', async () => {
    const { unmount } = render(
      <Harness folder="INBOX" overrides={{ bulkMode: true, selected: new Set([1, 2]) }} />,
    );
    try {
      await waitFor(() => {
        expect(screen.getByRole('button', { name: /mark read/i })).toBeInTheDocument();
      });
      mockGetMessages.mockClear();

      await act(async () => {
        fireEvent.click(screen.getByRole('button', { name: /mark read/i }));
      });
      await flush();

      expect(mockSetFlag).toHaveBeenCalledWith(
        'INBOX', '\\Seen', 'set', [1, 2], 'REVERSE ', 'DATE',
      );
      expect(mockGetMessages).not.toHaveBeenCalled();
    } finally {
      unmount();
    }
  });
});

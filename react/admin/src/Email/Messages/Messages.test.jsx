import React from 'react';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Messages from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';
import { DATE, DESC } from '../../constants';

const mockGetMessages = vi.fn();
const mockSetFlag = vi.fn();
const mockMoveMessages = vi.fn();
const mockGetEnvelopes = vi.fn().mockResolvedValue({ data: { envelopes: {} } });
const mockGetFolderList = vi.fn().mockResolvedValue({ data: { folders: [], sub_folders: [] } });

const mockApi = {
  getMessages: mockGetMessages,
  setFlag: mockSetFlag,
  moveMessages: mockMoveMessages,
  getEnvelopes: mockGetEnvelopes,
  getFolderList: mockGetFolderList,
};

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
  const setMessage = vi.fn();
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
    mockGetMessages.mockResolvedValue({ data: { message_ids: [1, 2, 3] } });
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
});

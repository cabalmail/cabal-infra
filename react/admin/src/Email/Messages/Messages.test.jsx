import { render, screen, waitFor, act } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Messages from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

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
const setMessage = vi.fn();

function renderMessages(props = {}) {
  return render(
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage }}>
        <Messages
          token="tok"
          api_url="http://api"
          folder="INBOX"
          host="host"
          showOverlay={vi.fn()}
          setFolder={vi.fn()}
          setMessage={setMessage}
          {...props}
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
    const { unmount } = renderMessages();
    expect(screen.getByText('Loading...')).toBeInTheDocument();
    // Flush pending effects so we don't pollute the next test
    await act(async () => { await Promise.resolve(); });
    unmount();
  });

  it('fetches messages and switches folders correctly', async () => {
    const { rerender, unmount } = renderMessages({ folder: 'INBOX' });
    try {
      await waitFor(() => {
        expect(mockGetMessages).toHaveBeenCalledWith('INBOX', 'REVERSE ', 'DATE');
      });
      mockGetMessages.mockClear();

      rerender(
        <AuthContext.Provider value={authValue}>
          <AppMessageContext.Provider value={{ setMessage }}>
            <Messages
              token="tok"
              api_url="http://api"
              folder="Archive"
              host="host"
              showOverlay={vi.fn()}
              setFolder={vi.fn()}
              setMessage={setMessage}
            />
          </AppMessageContext.Provider>
        </AuthContext.Provider>
      );

      await waitFor(() => {
        expect(mockGetMessages).toHaveBeenCalledWith('Archive', 'REVERSE ', 'DATE');
      });
    } finally {
      unmount();
    }
  });

  it('shows error message when fetch fails', async () => {
    mockGetMessages.mockRejectedValueOnce(new Error('Network error'));
    // Subsequent polls succeed (so we don't keep erroring)
    mockGetMessages.mockResolvedValue({ data: { message_ids: [] } });

    const { unmount } = renderMessages();
    try {
      await waitFor(() => {
        expect(setMessage).toHaveBeenCalledWith('Unable to get list of messages.', true);
      });
    } finally {
      unmount();
    }
  });
});

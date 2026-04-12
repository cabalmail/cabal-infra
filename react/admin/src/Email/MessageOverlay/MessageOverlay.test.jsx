import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import MessageOverlay from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

const mockGetMessage = vi.fn().mockResolvedValue({
  data: {
    message_raw: 'http://raw.url',
    message_body_plain: 'plain text body',
    message_body_html: '<p>html body</p>',
    recipient: 'me@test.com',
    message_id: ['<msg1@test>'],
    in_reply_to: [],
    references: [],
  },
});
const mockGetAttachments = vi.fn().mockResolvedValue({
  data: { attachments: [] },
});
const mockGetBimiUrl = vi.fn().mockResolvedValue({
  data: { url: '/bimi.png' },
});
const mockGetAddresses = vi.fn().mockResolvedValue({
  data: { Items: [{ address: 'me@test.com', subdomain: 'sub', tld: 'com', public_key: 'pk' }] },
});
const mockGetEnvelopes = vi.fn().mockResolvedValue({
  data: { envelopes: { 1: { id: 1 } } },
});

const mockApi = {
  getMessage: mockGetMessage,
  getAttachments: mockGetAttachments,
  getBimiUrl: mockGetBimiUrl,
  getAddresses: mockGetAddresses,
  getEnvelopes: mockGetEnvelopes,
  getAttachment: vi.fn().mockResolvedValue({ data: { url: 'http://dl.url' } }),
  deleteAddress: vi.fn().mockResolvedValue({}),
  getFolderList: vi.fn().mockResolvedValue({ data: { folders: [], sub_folders: [] } }),
  setFlag: vi.fn().mockResolvedValue({}),
  moveMessages: vi.fn().mockResolvedValue({}),
};

vi.mock('../../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };
const setMessage = vi.fn();

const testEnvelope = {
  id: 1,
  from: ['sender@example.com'],
  to: ['me@test.com'],
  cc: [],
  subject: 'Test Subject',
  date: '2024-01-01',
  flags: ['\\Seen'],
};

function renderOverlay(props = {}) {
  return render(
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage }}>
        <MessageOverlay
          envelope={testEnvelope}
          folder="INBOX"
          visible={true}
          flags={['\\Seen']}
          hide={vi.fn()}
          updateOverlay={vi.fn()}
          reply={vi.fn()}
          replyAll={vi.fn()}
          forward={vi.fn()}
          token="tok"
          api_url="http://api"
          host="host"
          {...props}
        />
      </AppMessageContext.Provider>
    </AuthContext.Provider>
  );
}

describe('MessageOverlay', () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it('fetches message data when envelope has an id', async () => {
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => {
        expect(mockGetMessage).toHaveBeenCalledWith('INBOX', 1, true);
      });
      await waitFor(() => {
        expect(mockGetAttachments).toHaveBeenCalledWith('INBOX', 1, true);
      });
      await waitFor(() => {
        expect(mockGetBimiUrl).toHaveBeenCalledWith('sender@example.com');
      });
    } finally {
      unmount();
    }
  });

  it('renders header info from envelope', async () => {
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => {
        expect(screen.getByText('sender@example.com')).toBeInTheDocument();
      });
      expect(screen.getByText('me@test.com')).toBeInTheDocument();
      expect(screen.getByText('Test Subject')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('renders nothing visible when visible=false', async () => {
    const { container, unmount } = renderOverlay({ visible: false });
    try {
      expect(container.querySelector('.overlay_hidden')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('switches view tabs', async () => {
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => {
        expect(mockGetMessage).toHaveBeenCalled();
      });
      fireEvent.click(screen.getByText('Plain Text'));
      await waitFor(() => {
        expect(screen.getByText('plain text body')).toBeInTheDocument();
      });
    } finally {
      unmount();
    }
  });

  it('calls hide when close button is clicked', async () => {
    const hide = vi.fn();
    const { unmount } = renderOverlay({ hide });
    try {
      await act(async () => { await Promise.resolve(); });
      fireEvent.click(screen.getByTitle('Close message'));
      expect(hide).toHaveBeenCalled();
    } finally {
      unmount();
    }
  });

  it('shows error when message fetch fails', async () => {
    mockGetMessage.mockRejectedValueOnce(new Error('fail'));
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => {
        expect(setMessage).toHaveBeenCalledWith('Unable to get message.', true);
      });
    } finally {
      unmount();
    }
  });
});

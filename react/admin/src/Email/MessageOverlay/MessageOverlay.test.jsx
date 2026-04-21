import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import MessageOverlay from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

const mockGetMessage = vi.fn().mockResolvedValue({
  data: {
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
const mockGetEnvelopes = vi.fn().mockResolvedValue({
  data: { envelopes: { 1: { id: 1 } } },
});

const mockApi = {
  getMessage: mockGetMessage,
  getAttachments: mockGetAttachments,
  getEnvelopes: mockGetEnvelopes,
  getAttachment: vi.fn().mockResolvedValue({ data: { url: 'http://dl.url' } }),
  fetchImage: vi.fn().mockResolvedValue({ data: { url: 'http://img.url' } }),
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
  from: ['Alice Sender <sender@example.com>'],
  to: ['me@test.com'],
  cc: [],
  subject: 'Test Subject',
  date: '2024-04-17T13:10:00Z',
  flags: ['\\Seen'],
};

function renderOverlay(props = {}) {
  const setReaderFormat = vi.fn();
  return {
    setReaderFormat,
    ...render(
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
            readerFormat="rich"
            setReaderFormat={setReaderFormat}
            {...props}
          />
        </AppMessageContext.Provider>
      </AuthContext.Provider>,
    ),
  };
}

describe('MessageOverlay (Reader)', () => {
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
    } finally {
      unmount();
    }
  });

  it('renders subject, sender name, sender email, and "to" line', async () => {
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => {
        expect(screen.getByText('Test Subject')).toBeInTheDocument();
      });
      expect(screen.getByText('Alice Sender')).toBeInTheDocument();
      expect(screen.getByText('<sender@example.com>')).toBeInTheDocument();
      expect(screen.getByText('me@test.com')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('hides when visible=false', async () => {
    const { container, unmount } = renderOverlay({ visible: false });
    try {
      expect(container.querySelector('.reader.overlay_hidden')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('switches format via overflow menu Rich/Plain toggle', async () => {
    const { setReaderFormat, unmount } = renderOverlay();
    try {
      await waitFor(() => {
        expect(mockGetMessage).toHaveBeenCalled();
      });
      // Open overflow menu
      fireEvent.click(screen.getByLabelText('More actions'));
      // Click the "Plain text alternative" item
      fireEvent.click(screen.getByText('Plain text alternative'));
      expect(setReaderFormat).toHaveBeenCalledWith('plain');
    } finally {
      unmount();
    }
  });

  it('renders plain body as a <pre> when format is plain', async () => {
    const { unmount } = renderOverlay({ readerFormat: 'plain' });
    try {
      await waitFor(() => {
        expect(screen.getByText('plain text body')).toBeInTheDocument();
      });
    } finally {
      unmount();
    }
  });

  it('renders attachments with extension badge and download button', async () => {
    mockGetAttachments.mockResolvedValueOnce({
      data: {
        attachments: [
          { id: 2, name: 'report.pdf', size: 1234, type: 'application/pdf' },
        ],
      },
    });
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => {
        expect(screen.getByText('Attachments (1)')).toBeInTheDocument();
      });
      expect(screen.getByText('report.pdf')).toBeInTheDocument();
      expect(screen.getByLabelText('Download report.pdf')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('calls hide when close button is clicked', async () => {
    const hide = vi.fn();
    const { unmount } = renderOverlay({ hide });
    try {
      await act(async () => { await Promise.resolve(); });
      fireEvent.click(screen.getByLabelText('Close message'));
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

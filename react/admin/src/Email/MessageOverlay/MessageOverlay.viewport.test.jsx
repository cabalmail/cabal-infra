/* Phase 8 — viewport tests for the MessageOverlay reader:
   floating tab bar on phone, retry card on load error. */

import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import MessageOverlay from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';
import { setViewport, PHONE, TABLET, DESKTOP } from '../../test/viewport';

const mockGetMessage = vi.fn();
const mockGetAttachments = vi.fn().mockResolvedValue({ data: { attachments: [] } });

const mockApi = {
  getMessage: mockGetMessage,
  getAttachments: mockGetAttachments,
  getEnvelopes: vi.fn().mockResolvedValue({ data: { envelopes: {} } }),
  getAttachment: vi.fn(),
  getRawMessage: vi.fn(),
  fetchImage: vi.fn(),
  setFlag: vi.fn().mockResolvedValue({}),
  moveMessages: vi.fn().mockResolvedValue({}),
};

vi.mock('../../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };

const envelope = {
  id: 1,
  from: ['Alice <a@b.com>'],
  to: ['me@test.com'],
  cc: [],
  subject: 'Hello',
  date: '2024-04-17T13:10:00Z',
  flags: ['\\Seen'],
};

function renderReader(layout, props = {}) {
  return render(
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage: vi.fn() }}>
        <MessageOverlay
          envelope={envelope}
          folder="INBOX"
          visible
          flags={['\\Seen']}
          hide={vi.fn()}
          updateOverlay={vi.fn()}
          reply={vi.fn()}
          replyAll={vi.fn()}
          forward={vi.fn()}
          readerFormat="rich"
          setReaderFormat={vi.fn()}
          layout={layout}
          {...props}
        />
      </AppMessageContext.Provider>
    </AuthContext.Provider>,
  );
}

describe('MessageOverlay (viewport)', () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it('renders the floating tab bar on phone layout', async () => {
    setViewport(...PHONE);
    mockGetMessage.mockResolvedValueOnce({
      data: {
        message_body_plain: 'x', message_body_html: '<p>x</p>',
        message_raw: null, recipient: '', message_id: [],
        in_reply_to: [], references: [],
      },
    });
    const { container, unmount } = renderReader('phone');
    try {
      await waitFor(() => expect(screen.getByText('Hello')).toBeInTheDocument());
      expect(container.querySelector('.reader-tabbar')).toBeTruthy();
      expect(container.querySelector('.reader[data-layout="sheet"]')).toBeTruthy();
    } finally {
      unmount();
    }
  });

  it('does not render a tab bar on tablet layout', async () => {
    setViewport(...TABLET);
    mockGetMessage.mockResolvedValueOnce({
      data: {
        message_body_plain: 'x', message_body_html: '<p>x</p>',
        message_raw: null, recipient: '', message_id: [],
        in_reply_to: [], references: [],
      },
    });
    const { container, unmount } = renderReader('tablet');
    try {
      await waitFor(() => expect(screen.getByText('Hello')).toBeInTheDocument());
      expect(container.querySelector('.reader-tabbar')).toBeFalsy();
    } finally {
      unmount();
    }
  });

  it('does not render a tab bar on desktop layout', async () => {
    setViewport(...DESKTOP);
    mockGetMessage.mockResolvedValueOnce({
      data: {
        message_body_plain: 'x', message_body_html: '<p>x</p>',
        message_raw: null, recipient: '', message_id: [],
        in_reply_to: [], references: [],
      },
    });
    const { container, unmount } = renderReader('desktop');
    try {
      await waitFor(() => expect(screen.getByText('Hello')).toBeInTheDocument());
      expect(container.querySelector('.reader-tabbar')).toBeFalsy();
    } finally {
      unmount();
    }
  });

  it('renders the shimmer skeleton while loading', () => {
    setViewport(...PHONE);
    mockGetMessage.mockImplementation(() => new Promise(() => {})); // never resolves
    const { container, unmount } = renderReader('phone');
    try {
      expect(container.querySelector('.reader-skel')).toBeTruthy();
      expect(container.querySelectorAll('.reader-skel-para').length).toBe(3);
    } finally {
      unmount();
    }
  });

  it('renders the retry card when message fetch fails, and retry re-fetches', async () => {
    setViewport(...PHONE);
    mockGetMessage.mockRejectedValueOnce(new Error('boom'));
    mockGetMessage.mockResolvedValueOnce({
      data: {
        message_body_plain: 'ok', message_body_html: '<p>ok</p>',
        message_raw: null, recipient: '', message_id: [],
        in_reply_to: [], references: [],
      },
    });
    const { unmount } = renderReader('phone');
    try {
      await waitFor(() => expect(screen.getByText(/Couldn.t load this message/i)).toBeInTheDocument());
      const retryBtn = screen.getByRole('button', { name: 'Retry' });
      fireEvent.click(retryBtn);
      await waitFor(() => expect(mockGetMessage).toHaveBeenCalledTimes(2));
      await waitFor(() => expect(screen.getByText('Hello')).toBeInTheDocument());
    } finally {
      unmount();
    }
  });
});

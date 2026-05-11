import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import ComposeOverlay from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

const mockGetAddresses = vi.fn().mockResolvedValue({
  data: { Items: [{ address: 'user@test.com' }, { address: 'other@test.com' }] }
});
const mockSendMessage = vi.fn().mockResolvedValue({});
const mockGetAttachmentUploadUrls = vi.fn();
const mockUploadAttachmentToS3 = vi.fn().mockResolvedValue({});

const mockApi = {
  getAddresses: mockGetAddresses,
  sendMessage: mockSendMessage,
  getAttachmentUploadUrls: mockGetAttachmentUploadUrls,
  uploadAttachmentToS3: mockUploadAttachmentToS3,
  newAddress: vi.fn().mockResolvedValue({ data: { address: 'new@test.com' } }),
};

vi.mock('../../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = {
  token: 'tok',
  api_url: 'http://api',
  host: 'host',
  domains: [{ domain: 'test.com' }],
  smtp_host: 'smtp.test.com',
};
const setMessage = vi.fn();

const EMPTY_ENVELOPE = { from: [], to: [], cc: [], subject: '' };

function renderCompose(props = {}) {
  return render(
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage }}>
        <ComposeOverlay
          hide={vi.fn()}
          body=""
          recipient=""
          envelope={EMPTY_ENVELOPE}
          subject=""
          type="new"
          other_headers={{ in_reply_to: [], references: [], message_id: [] }}
          smtp_host="smtp.test.com"
          domains={[{ domain: 'test.com' }]}
          stackIndex={0}
          composeFromAddress={null}
          setComposeFromAddress={vi.fn()}
          {...props}
        />
      </AppMessageContext.Provider>
    </AuthContext.Provider>
  );
}

describe('ComposeOverlay', () => {
  afterEach(() => {
    vi.clearAllMocks();
  });

  it('renders floating chrome with From, To, Subject, Send, and Close', async () => {
    const { unmount } = renderCompose();
    try {
      expect(screen.getByText('New message')).toBeInTheDocument();
      expect(screen.getByLabelText('From')).toBeInTheDocument();
      expect(screen.getByLabelText('Recipients')).toBeInTheDocument();
      expect(screen.getByLabelText('Subject')).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Send' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Close' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Minimize' })).toBeInTheDocument();
      await act(async () => { await Promise.resolve(); });
    } finally {
      unmount();
    }
  });

  it('fetches addresses on mount', async () => {
    const { unmount } = renderCompose();
    try {
      await waitFor(() => {
        expect(mockGetAddresses).toHaveBeenCalled();
      });
    } finally {
      unmount();
    }
  });

  it('opens the From picker and writes back the chosen address', async () => {
    const setComposeFromAddress = vi.fn();
    const { unmount } = renderCompose({ setComposeFromAddress });
    try {
      await waitFor(() => {
        expect(mockGetAddresses).toHaveBeenCalled();
      });
      // No default address is pre-selected — the user must choose explicitly.
      await waitFor(() => {
        expect(screen.getByLabelText('From').textContent).toMatch(/Select address/);
      });
      fireEvent.click(screen.getByLabelText('From'));
      const option = await screen.findByRole('option', { name: /user@test\.com/ });
      fireEvent.click(option);
      expect(setComposeFromAddress).toHaveBeenCalledWith('user@test.com');
    } finally {
      unmount();
    }
  });

  it('toggles Cc / Bcc rows', async () => {
    const { unmount } = renderCompose();
    try {
      await waitFor(() => {
        expect(mockGetAddresses).toHaveBeenCalled();
      });
      expect(screen.queryByLabelText('Cc')).not.toBeInTheDocument();
      fireEvent.click(screen.getByRole('button', { name: /Cc Bcc/ }));
      expect(screen.getByLabelText('Cc')).toBeInTheDocument();
      expect(screen.getByLabelText('Bcc')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('populates subject for reply type', async () => {
    const envelope = { from: ['sender@example.com'], to: ['me@test.com'], cc: [], subject: 'Test' };
    const { unmount } = renderCompose({
      type: 'reply',
      envelope,
      recipient: 'me@test.com',
      subject: 'Re: Test',
    });
    try {
      await waitFor(() => {
        expect(screen.getByDisplayValue('Re: Test')).toBeInTheDocument();
      });
    } finally {
      unmount();
    }
  });

  it('populates To and CC for replyAll type', async () => {
    const envelope = {
      from: ['sender@example.com'],
      to: ['me@test.com', 'other@example.com'],
      cc: ['cc@example.com'],
      subject: 'Test',
    };
    const { unmount } = renderCompose({
      type: 'replyAll',
      envelope,
      recipient: 'me@test.com',
      subject: 'Re: Test',
    });
    try {
      await waitFor(() => {
        expect(screen.getByLabelText('Cc')).toBeInTheDocument();
      });
    } finally {
      unmount();
    }
  });

  it('strips self from replyAll recipients when entries carry display names', async () => {
    const envelope = {
      from: ['"Sender" <sender@example.com>'],
      to: ['"Me" <me@test.com>', '"Other" <other@example.com>'],
      cc: ['"Me Again" <me@test.com>', '"Cc Person" <cc@example.com>'],
      subject: 'Test',
    };
    const { unmount } = renderCompose({
      type: 'replyAll',
      envelope,
      recipient: 'me@test.com',
      subject: 'Re: Test',
    });
    try {
      await waitFor(() => {
        expect(screen.getByLabelText('Cc')).toBeInTheDocument();
      });
      // Self should not appear in To or Cc; the wrapped non-self entries should.
      expect(screen.queryByText('"Me" <me@test.com>')).not.toBeInTheDocument();
      expect(screen.queryByText('"Me Again" <me@test.com>')).not.toBeInTheDocument();
      expect(screen.getByText('"Sender" <sender@example.com>')).toBeInTheDocument();
      expect(screen.getByText('"Other" <other@example.com>')).toBeInTheDocument();
      expect(screen.getByText('"Cc Person" <cc@example.com>')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('calls hide when the chrome close button is clicked', async () => {
    const hide = vi.fn();
    const { unmount } = renderCompose({ hide });
    try {
      fireEvent.click(screen.getByRole('button', { name: 'Close' }));
      expect(hide).toHaveBeenCalled();
    } finally {
      unmount();
    }
  });

  it('shows validation error when sending with no recipients', async () => {
    const { unmount } = renderCompose();
    try {
      await waitFor(() => {
        expect(mockGetAddresses).toHaveBeenCalled();
      });
      fireEvent.click(screen.getByRole('button', { name: 'Send' }));
      expect(setMessage).toHaveBeenCalledWith('Please specify at least one recipient.', true);
    } finally {
      unmount();
    }
  });

  it('offsets the second compose window by stackIndex', async () => {
    const { container, unmount } = renderCompose({ stackIndex: 1 });
    try {
      const overlay = container.querySelector('.compose-overlay');
      expect(overlay).not.toBeNull();
      // 24 + 1 * (600 + 8) = 632
      expect(overlay.style.right).toBe('632px');
    } finally {
      unmount();
    }
  });

  it('uploads an attached file to S3 and forwards its key to /send', async () => {
    mockGetAttachmentUploadUrls.mockResolvedValueOnce({
      data: { uploads: [{ key: 'outbound/cog-user/uuid/note.txt', url: 'https://s3/put' }] }
    });
    const { container, unmount } = renderCompose();
    try {
      await waitFor(() => {
        expect(mockGetAddresses).toHaveBeenCalled();
      });

      // Pick a From address.
      fireEvent.click(screen.getByLabelText('From'));
      fireEvent.click(await screen.findByRole('option', { name: /user@test\.com/ }));

      // Add a recipient and a subject so canSend is satisfied.
      const toInput = screen.getByLabelText('Recipients');
      fireEvent.change(toInput, { target: { value: 'dest@test.com' } });
      fireEvent.keyDown(toInput, { key: 'Enter' });
      fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'hi' } });

      // Drop a tiny file onto the hidden file input.
      const fileInput = container.querySelector('.compose-attachment-input');
      expect(fileInput).not.toBeNull();
      const file = new File(['hello'], 'note.txt', { type: 'text/plain' });
      fireEvent.change(fileInput, { target: { files: [file] } });

      await waitFor(() => {
        expect(screen.getByText('note.txt')).toBeInTheDocument();
      });

      fireEvent.click(screen.getByRole('button', { name: 'Send' }));

      await waitFor(() => {
        expect(mockGetAttachmentUploadUrls).toHaveBeenCalled();
      });
      const urlArgs = mockGetAttachmentUploadUrls.mock.calls[0][0];
      expect(urlArgs).toHaveLength(1);
      expect(urlArgs[0].filename).toBe('note.txt');
      expect(urlArgs[0].mimeType).toBe('text/plain');

      await waitFor(() => {
        expect(mockUploadAttachmentToS3).toHaveBeenCalledWith('https://s3/put', file);
      });

      await waitFor(() => {
        expect(mockSendMessage).toHaveBeenCalled();
      });
      const args = mockSendMessage.mock.calls[0];
      // signature: smtp_host, sender, to, cc, bcc, subject, headers, html, text, draft, attachments
      const wireAttachments = args[10];
      expect(wireAttachments).toHaveLength(1);
      expect(wireAttachments[0]).toEqual({
        filename: 'note.txt',
        mime_type: 'text/plain',
        s3_key: 'outbound/cog-user/uuid/note.txt',
      });
    } finally {
      unmount();
    }
  });

  it('removes an attached file when the chip remove button is clicked', async () => {
    const { container, unmount } = renderCompose();
    try {
      await waitFor(() => {
        expect(mockGetAddresses).toHaveBeenCalled();
      });
      const fileInput = container.querySelector('.compose-attachment-input');
      const file = new File(['hello'], 'note.txt', { type: 'text/plain' });
      fireEvent.change(fileInput, { target: { files: [file] } });
      await waitFor(() => {
        expect(screen.getByText('note.txt')).toBeInTheDocument();
      });
      fireEvent.click(screen.getByRole('button', { name: 'Remove attachment note.txt' }));
      expect(screen.queryByText('note.txt')).not.toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('shows a warning when total attachment size exceeds 20 MB', async () => {
    const { container, unmount } = renderCompose();
    try {
      await waitFor(() => {
        expect(mockGetAddresses).toHaveBeenCalled();
      });
      const fileInput = container.querySelector('.compose-attachment-input');
      // A 21 MB blob — Blob isn't memory-backed for File constructor in
      // jsdom unless we feed bytes, so use a sparse buffer.
      const bigBytes = new Uint8Array(21 * 1024 * 1024);
      const big = new File([bigBytes], 'big.bin', { type: 'application/octet-stream' });
      fireEvent.change(fileInput, { target: { files: [big] } });
      await waitFor(() => {
        expect(screen.getByText('big.bin')).toBeInTheDocument();
      });
      expect(screen.getByRole('status').textContent).toMatch(/delivery may fail/i);
    } finally {
      unmount();
    }
  });
});

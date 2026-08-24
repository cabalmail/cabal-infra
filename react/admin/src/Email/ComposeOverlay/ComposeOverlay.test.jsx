import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import ComposeOverlay from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

const mockGetAddresses = vi.fn().mockResolvedValue({
  data: { Items: [{ address: 'user@test.com' }, { address: 'other@test.com' }] }
});
const mockSendMessage = vi.fn().mockResolvedValue({});
const mockSetFlag = vi.fn().mockResolvedValue({});
const mockGetAttachmentUploadUrls = vi.fn();
const mockUploadAttachmentToS3 = vi.fn().mockResolvedValue({});
const mockGetAttachment = vi.fn();
const mockDownloadAttachment = vi.fn();
const mockSaveDraft = vi.fn().mockResolvedValue({
  data: { status: 'saved', uid: 42, uidvalidity: 7, replaced: false }
});

const mockApi = {
  getAddresses: mockGetAddresses,
  sendMessage: mockSendMessage,
  setFlag: mockSetFlag,
  getAttachmentUploadUrls: mockGetAttachmentUploadUrls,
  uploadAttachmentToS3: mockUploadAttachmentToS3,
  getAttachment: mockGetAttachment,
  downloadAttachment: mockDownloadAttachment,
  saveDraft: mockSaveDraft,
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

  it('reply from Sent reuses the sending alias and targets the original To', async () => {
    const envelope = {
      from: ['"Me" <user@test.com>'],
      to: ['"Ann" <ann@vendor.example>', 'bob@vendor.example'],
      cc: ['carol@vendor.example'],
      subject: 'Plans',
    };
    const { unmount } = renderCompose({
      type: 'reply',
      envelope,
      recipient: '',
      subject: 'Re: Plans',
      reply_source: { folder: 'Sent', id: 7 },
    });
    try {
      await waitFor(() => {
        expect(screen.getByText('"Ann" <ann@vendor.example>')).toBeInTheDocument();
      });
      expect(screen.getByText('bob@vendor.example')).toBeInTheDocument();
      // Plain reply drops the Cc, and the author is never a recipient.
      expect(screen.queryByText('carol@vendor.example')).not.toBeInTheDocument();
      expect(screen.queryByText('"Me" <user@test.com>')).not.toBeInTheDocument();
      // The From alias survives the owned-list reconciliation.
      await waitFor(() => {
        expect(screen.getByLabelText('From')).toHaveTextContent('user@test.com');
      });
    } finally {
      unmount();
    }
  });

  it('replyAll from Sent carries the original Cc and Bcc without the blind-copy warning', async () => {
    const envelope = {
      from: ['"Me" <user@test.com>'],
      to: ['ann@vendor.example'],
      cc: ['carol@vendor.example'],
      bcc: ['eve@home.example'],
      subject: 'Plans',
    };
    const { unmount } = renderCompose({
      type: 'replyAll',
      envelope,
      recipient: '',
      subject: 'Re: Plans',
      reply_source: { folder: 'Sent', id: 7 },
    });
    try {
      await waitFor(() => {
        expect(screen.getByText('eve@home.example')).toBeInTheDocument();
      });
      expect(screen.getByText('ann@vendor.example')).toBeInTheDocument();
      expect(screen.getByText('carol@vendor.example')).toBeInTheDocument();
      expect(setMessage).not.toHaveBeenCalledWith(
        'Warning: You are replying to a blind copy.', true
      );
    } finally {
      unmount();
    }
  });

  it('clears a Sent-derived From the user no longer owns', async () => {
    const envelope = {
      from: ['gone@test.com'],
      to: ['ann@vendor.example'],
      cc: [],
      subject: 'Plans',
    };
    const { unmount } = renderCompose({
      type: 'reply',
      envelope,
      recipient: '',
      subject: 'Re: Plans',
      reply_source: { folder: 'Sent', id: 7 },
    });
    try {
      await waitFor(() => {
        expect(mockGetAddresses).toHaveBeenCalled();
      });
      // The revoked alias must not survive into the From picker.
      await waitFor(() => {
        expect(screen.getByLabelText('From')).not.toHaveTextContent('gone@test.com');
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

  // Regression: the recipient input is committed to a chip by the same click
  // that fires Send, so validating (and sending) the To/CC/BCC state read
  // pre-flush — the first click was rejected as recipient-less while the
  // address was on screen, and a second uncommitted address was dropped.
  describe('uncommitted recipient text', () => {
    async function fillAndPickFrom() {
      await waitFor(() => {
        expect(mockGetAddresses).toHaveBeenCalled();
      });
      fireEvent.click(screen.getByLabelText('From'));
      fireEvent.click(await screen.findByRole('option', { name: /user@test\.com/ }));
      fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'hi' } });
    }

    it('sends on the first click when the address was never committed with Enter', async () => {
      const { unmount } = renderCompose();
      try {
        await fillAndPickFrom();
        // Typed, then left alone — no Enter, no comma.
        fireEvent.change(screen.getByLabelText('Recipients'), {
          target: { value: 'dest@test.com' }
        });

        fireEvent.click(screen.getByRole('button', { name: 'Send' }));

        await waitFor(() => {
          expect(mockSendMessage).toHaveBeenCalled();
        });
        expect(mockSendMessage.mock.calls[0][2]).toEqual(['dest@test.com']);
        expect(setMessage).not.toHaveBeenCalledWith(
          'Please specify at least one recipient.', true
        );
      } finally {
        unmount();
      }
    });

    it('keeps an uncommitted second recipient in the sent message', async () => {
      const { unmount } = renderCompose();
      try {
        await fillAndPickFrom();
        const toInput = screen.getByLabelText('Recipients');
        fireEvent.change(toInput, { target: { value: 'first@test.com' } });
        fireEvent.keyDown(toInput, { key: 'Enter' });
        fireEvent.change(toInput, { target: { value: 'second@test.com' } });

        fireEvent.click(screen.getByRole('button', { name: 'Send' }));

        await waitFor(() => {
          expect(mockSendMessage).toHaveBeenCalled();
        });
        expect(mockSendMessage.mock.calls[0][2]).toEqual(['first@test.com', 'second@test.com']);
      } finally {
        unmount();
      }
    });

    it('commits uncommitted Bcc text to Bcc, not To', async () => {
      const { unmount } = renderCompose();
      try {
        await fillAndPickFrom();
        const toInput = screen.getByLabelText('Recipients');
        fireEvent.change(toInput, { target: { value: 'dest@test.com' } });
        fireEvent.keyDown(toInput, { key: 'Enter' });

        fireEvent.click(screen.getByRole('button', { name: /Cc Bcc/ }));
        fireEvent.change(screen.getByLabelText('Bcc'), {
          target: { value: 'blind@test.com' }
        });

        fireEvent.click(screen.getByRole('button', { name: 'Send' }));

        await waitFor(() => {
          expect(mockSendMessage).toHaveBeenCalled();
        });
        const args = mockSendMessage.mock.calls[0];
        expect(args[2]).toEqual(['dest@test.com']);
        expect(args[4]).toEqual(['blind@test.com']);
      } finally {
        unmount();
      }
    });
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

  describe('forwarded attachments', () => {
    const FWD_ENVELOPE = { from: ['sender@example.com'], to: ['me@test.com'], cc: [], subject: 'Test' };
    const FWD_SOURCE = {
      folder: 'INBOX',
      id: 42,
      seen: true,
      attachments: [{ name: 'report.pdf', type: 'application/pdf', size: 5, id: 2 }],
    };

    function renderForward(source = FWD_SOURCE) {
      return renderCompose({
        type: 'forward',
        envelope: FWD_ENVELOPE,
        recipient: 'me@test.com',
        subject: 'Fwd: Test',
        forward_attachments: source,
      });
    }

    it('carries the original attachments into the compose window and sends them', async () => {
      const blob = new Blob(['12345'], { type: 'application/pdf' });
      mockGetAttachment.mockResolvedValueOnce({ data: { url: 'https://s3/get' } });
      mockDownloadAttachment.mockResolvedValueOnce({ data: blob });
      mockGetAttachmentUploadUrls.mockResolvedValueOnce({
        data: { uploads: [{ key: 'outbound/cog-user/uuid/report.pdf', url: 'https://s3/put' }] }
      });
      const { unmount } = renderForward();
      try {
        // Chip appears immediately (pending), then resolves once the Blob lands.
        expect(screen.getByText('report.pdf')).toBeInTheDocument();
        expect(screen.getByText('loading…')).toBeInTheDocument();
        await waitFor(() => {
          expect(screen.queryByText('loading…')).not.toBeInTheDocument();
        });
        expect(mockGetAttachment).toHaveBeenCalledWith(
          FWD_SOURCE.attachments[0], 'INBOX', 42, true
        );
        expect(mockDownloadAttachment).toHaveBeenCalledWith('https://s3/get');

        // Complete the form and send — the forwarded Blob goes up like a
        // hand-picked file.
        fireEvent.click(screen.getByLabelText('From'));
        fireEvent.click(await screen.findByRole('option', { name: /user@test\.com/ }));
        const toInput = screen.getByLabelText('Recipients');
        fireEvent.change(toInput, { target: { value: 'dest@test.com' } });
        fireEvent.keyDown(toInput, { key: 'Enter' });
        fireEvent.click(screen.getByRole('button', { name: 'Send' }));

        await waitFor(() => {
          expect(mockUploadAttachmentToS3).toHaveBeenCalledWith('https://s3/put', blob);
        });
        await waitFor(() => {
          expect(mockSendMessage).toHaveBeenCalled();
        });
        const wireAttachments = mockSendMessage.mock.calls[0][10];
        expect(wireAttachments).toEqual([{
          filename: 'report.pdf',
          mime_type: 'application/pdf',
          s3_key: 'outbound/cog-user/uuid/report.pdf',
        }]);
      } finally {
        unmount();
      }
    });

    it('blocks Send while a forwarded attachment is still downloading', async () => {
      mockGetAttachment.mockReturnValueOnce(new Promise(() => {})); // never resolves
      const { unmount } = renderForward();
      try {
        await waitFor(() => {
          expect(mockGetAddresses).toHaveBeenCalled();
        });
        fireEvent.click(screen.getByLabelText('From'));
        fireEvent.click(await screen.findByRole('option', { name: /user@test\.com/ }));
        const toInput = screen.getByLabelText('Recipients');
        fireEvent.change(toInput, { target: { value: 'dest@test.com' } });
        fireEvent.keyDown(toInput, { key: 'Enter' });
        fireEvent.click(screen.getByRole('button', { name: 'Send' }));
        expect(setMessage).toHaveBeenCalledWith(
          'Attachments are still loading — please wait a moment.', true
        );
        expect(mockSendMessage).not.toHaveBeenCalled();
      } finally {
        unmount();
      }
    });

    it('drops the chip and warns when a forwarded attachment fails to download', async () => {
      mockGetAttachment.mockRejectedValueOnce(new Error('boom'));
      const { unmount } = renderForward();
      try {
        expect(screen.getByText('report.pdf')).toBeInTheDocument();
        await waitFor(() => {
          expect(screen.queryByText('report.pdf')).not.toBeInTheDocument();
        });
        expect(setMessage).toHaveBeenCalledWith(
          'Couldn\'t carry over attachment "report.pdf" from the original message.', true
        );
      } finally {
        unmount();
      }
    });

    it('allows removing a forwarded attachment before it finishes downloading', async () => {
      mockGetAttachment.mockReturnValueOnce(new Promise(() => {}));
      const { unmount } = renderForward();
      try {
        expect(screen.getByText('report.pdf')).toBeInTheDocument();
        fireEvent.click(screen.getByRole('button', { name: 'Remove attachment report.pdf' }));
        expect(screen.queryByText('report.pdf')).not.toBeInTheDocument();
        await act(async () => { await Promise.resolve(); });
      } finally {
        unmount();
      }
    });
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

  describe('draft autosave (/save_draft)', () => {
    it('shows "Draft not saved" on a fresh, un-typed compose (no timestamp label)', async () => {
      const { container, unmount } = renderCompose();
      try {
        await waitFor(() => {
          expect(mockGetAddresses).toHaveBeenCalled();
        });
        // The Saved indicator lives in .compose-saved. Regression guard for
        // issue #718: the pre-fix stub set "Saved just now" on mount even
        // with no content — that lie is what let closing feel safe.
        const label = container.querySelector('.compose-saved');
        expect(label.textContent).toMatch(/Draft not saved/i);
        expect(label.textContent).not.toMatch(/Saved just now/);
      } finally {
        unmount();
      }
    });

    it('does not autosave when nothing has been typed', async () => {
      vi.useFakeTimers({ shouldAdvanceTime: true });
      try {
        const { unmount } = renderCompose();
        try {
          await waitFor(() => {
            expect(mockGetAddresses).toHaveBeenCalled();
          });
          // Advance far past the debounce; performServerSave's hasContent
          // gate should keep /save_draft from ever firing.
          await act(async () => {
            vi.advanceTimersByTime(60000);
            await Promise.resolve();
          });
          expect(mockSaveDraft).not.toHaveBeenCalled();
        } finally {
          unmount();
        }
      } finally {
        vi.useRealTimers();
      }
    });

    it('fires /save_draft after a typing pause and marks the draft saved', async () => {
      vi.useFakeTimers({ shouldAdvanceTime: true });
      try {
        const { container, unmount } = renderCompose();
        try {
          await waitFor(() => {
            expect(mockGetAddresses).toHaveBeenCalled();
          });
          // Pick a From (server rejects unauthorized senders, so autosave
          // gates on this too).
          fireEvent.click(screen.getByLabelText('From'));
          fireEvent.click(await screen.findByRole('option', { name: /user@test\.com/ }));
          fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'hello' } });

          // Drive the 3s debounce past the fire point.
          await act(async () => {
            vi.advanceTimersByTime(4000);
            await Promise.resolve();
          });

          await waitFor(() => {
            expect(mockSaveDraft).toHaveBeenCalled();
          });
          const args = mockSaveDraft.mock.calls[0][0];
          expect(args.sender).toBe('user@test.com');
          expect(args.subject).toBe('hello');
          expect(args.op).toBe('save');
          // First save: no prior copy to replace.
          expect(args.replaces).toBeNull();

          // Label flips to the truthful "Saved just now" once the save
          // resolves.
          await waitFor(() => {
            expect(container.querySelector('.compose-saved').textContent)
              .toMatch(/Saved just now/);
          });
        } finally {
          unmount();
        }
      } finally {
        vi.useRealTimers();
      }
    });

    it('passes prior UIDPLUS coordinates as replaces_* on the next save', async () => {
      vi.useFakeTimers({ shouldAdvanceTime: true });
      try {
        mockSaveDraft
          .mockResolvedValueOnce({ data: { uid: 42, uidvalidity: 7 } })
          .mockResolvedValueOnce({ data: { uid: 43, uidvalidity: 7, replaced: true } });
        const { unmount } = renderCompose();
        try {
          await waitFor(() => {
            expect(mockGetAddresses).toHaveBeenCalled();
          });
          fireEvent.click(screen.getByLabelText('From'));
          fireEvent.click(await screen.findByRole('option', { name: /user@test\.com/ }));
          fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'first' } });
          await act(async () => {
            vi.advanceTimersByTime(4000);
            await Promise.resolve();
          });
          await waitFor(() => {
            expect(mockSaveDraft).toHaveBeenCalledTimes(1);
          });

          fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'second' } });
          await act(async () => {
            vi.advanceTimersByTime(4000);
            await Promise.resolve();
          });
          await waitFor(() => {
            expect(mockSaveDraft).toHaveBeenCalledTimes(2);
          });
          const secondCall = mockSaveDraft.mock.calls[1][0];
          expect(secondCall.replaces).toEqual({ uid: 42, uidvalidity: 7 });
        } finally {
          unmount();
        }
      } finally {
        vi.useRealTimers();
      }
    });

    it('flushes a pending draft on close-without-send', async () => {
      const hide = vi.fn();
      const { unmount } = renderCompose({ hide });
      try {
        await waitFor(() => {
          expect(mockGetAddresses).toHaveBeenCalled();
        });
        fireEvent.click(screen.getByLabelText('From'));
        fireEvent.click(await screen.findByRole('option', { name: /user@test\.com/ }));
        fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'quick note' } });

        // Close immediately — before the 3s debounce would have fired.
        fireEvent.click(screen.getByRole('button', { name: 'Close' }));
        expect(hide).toHaveBeenCalled();
        await waitFor(() => {
          expect(mockSaveDraft).toHaveBeenCalled();
        });
        expect(mockSaveDraft.mock.calls[0][0].subject).toBe('quick note');
      } finally {
        unmount();
      }
    });

    it('does not save on close when no content was entered', async () => {
      const hide = vi.fn();
      const { unmount } = renderCompose({ hide });
      try {
        await waitFor(() => {
          expect(mockGetAddresses).toHaveBeenCalled();
        });
        fireEvent.click(screen.getByRole('button', { name: 'Close' }));
        expect(hide).toHaveBeenCalled();
        // Give any spurious promise a tick to settle.
        await act(async () => { await Promise.resolve(); });
        expect(mockSaveDraft).not.toHaveBeenCalled();
      } finally {
        unmount();
      }
    });

    it('warns before discarding typed content when no From address is picked', async () => {
      const hide = vi.fn();
      const { unmount } = renderCompose({ hide });
      try {
        await waitFor(() => {
          expect(mockGetAddresses).toHaveBeenCalled();
        });
        // Type without picking a From. Autosave can't fire (server rejects
        // unauthorized senders), so a silent close would drop this content.
        fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'lost otherwise' } });

        fireEvent.click(screen.getByRole('button', { name: 'Close' }));

        // Overlay stays open — a confirm dialog appears instead.
        expect(hide).not.toHaveBeenCalled();
        expect(await screen.findByText(/Discard this draft/i)).toBeInTheDocument();
        expect(mockSaveDraft).not.toHaveBeenCalled();
      } finally {
        unmount();
      }
    });

    it('keeps the overlay open when the discard-confirm is cancelled', async () => {
      const hide = vi.fn();
      const { unmount } = renderCompose({ hide });
      try {
        await waitFor(() => {
          expect(mockGetAddresses).toHaveBeenCalled();
        });
        fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'still writing' } });
        fireEvent.click(screen.getByRole('button', { name: 'Close' }));
        fireEvent.click(await screen.findByRole('button', { name: 'Keep editing' }));

        expect(hide).not.toHaveBeenCalled();
        // Content survives — Subject is still there.
        expect(screen.getByLabelText('Subject').value).toBe('still writing');
      } finally {
        unmount();
      }
    });

    it('hides the overlay when the discard-confirm is confirmed', async () => {
      const hide = vi.fn();
      const { unmount } = renderCompose({ hide });
      try {
        await waitFor(() => {
          expect(mockGetAddresses).toHaveBeenCalled();
        });
        fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'goodbye' } });
        fireEvent.click(screen.getByRole('button', { name: 'Close' }));
        fireEvent.click(await screen.findByRole('button', { name: 'Discard' }));

        expect(hide).toHaveBeenCalled();
        // No draft save was attempted — the address gate blocks it either way.
        await act(async () => { await Promise.resolve(); });
        expect(mockSaveDraft).not.toHaveBeenCalled();
      } finally {
        unmount();
      }
    });

    it('passes discard_draft coordinates to /send after autosave wrote a copy', async () => {
      vi.useFakeTimers({ shouldAdvanceTime: true });
      try {
        mockSaveDraft.mockResolvedValueOnce({ data: { uid: 99, uidvalidity: 5 } });
        mockGetAttachmentUploadUrls.mockResolvedValueOnce({ data: { uploads: [] } });
        const { unmount } = renderCompose();
        try {
          await waitFor(() => {
            expect(mockGetAddresses).toHaveBeenCalled();
          });
          fireEvent.click(screen.getByLabelText('From'));
          fireEvent.click(await screen.findByRole('option', { name: /user@test\.com/ }));
          const toInput = screen.getByLabelText('Recipients');
          fireEvent.change(toInput, { target: { value: 'dest@test.com' } });
          fireEvent.keyDown(toInput, { key: 'Enter' });
          fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'hi' } });

          // Let autosave run to seed draftCoords.
          await act(async () => {
            vi.advanceTimersByTime(4000);
            await Promise.resolve();
          });
          await waitFor(() => {
            expect(mockSaveDraft).toHaveBeenCalled();
          });

          vi.useRealTimers();
          fireEvent.click(screen.getByRole('button', { name: 'Send' }));
          await waitFor(() => {
            expect(mockSendMessage).toHaveBeenCalled();
          });
          const discardArg = mockSendMessage.mock.calls[0][11];
          expect(discardArg).toEqual({ uid: 99, uidvalidity: 5 });
        } finally {
          unmount();
        }
      } finally {
        vi.useRealTimers();
      }
    });
  });
  // Issue #1031: a reply sent from React left the original unflagged, so the
  // replied indicator every client renders (React's reply icon, the Apple
  // message list since d56fa0b7) showed the message as unanswered no matter
  // where it was read.
  describe('\\Answered on the message being replied to', () => {
    async function composeAndSend(props) {
      const { unmount } = renderCompose(props);
      try {
        await waitFor(() => {
          expect(mockGetAddresses).toHaveBeenCalled();
        });
        fireEvent.click(screen.getByLabelText('From'));
        fireEvent.click(await screen.findByRole('option', { name: /user@test\.com/ }));
        fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'Re: hi' } });
        fireEvent.change(screen.getByLabelText('Recipients'), {
          target: { value: 'dest@test.com' }
        });
        fireEvent.click(screen.getByRole('button', { name: 'Send' }));
        await waitFor(() => {
          expect(mockSendMessage).toHaveBeenCalled();
        });
      } finally {
        unmount();
      }
    }

    it('flags the source message once a reply is away', async () => {
      await composeAndSend({
        type: 'reply',
        reply_source: { folder: 'INBOX', id: 74 },
      });
      await waitFor(() => {
        expect(mockSetFlag).toHaveBeenCalled();
      });
      const [folder, flag, op, ids] = mockSetFlag.mock.calls[0];
      expect(folder).toBe('INBOX');
      expect(flag).toBe('\\Answered');
      expect(op).toBe('set');
      expect(ids).toEqual([74]);
    });

    it('flags the source message for reply-all too', async () => {
      await composeAndSend({
        type: 'replyAll',
        reply_source: { folder: 'Archive', id: 12 },
      });
      await waitFor(() => {
        expect(mockSetFlag).toHaveBeenCalled();
      });
      expect(mockSetFlag.mock.calls[0][0]).toBe('Archive');
      expect(mockSetFlag.mock.calls[0][3]).toEqual([12]);
    });

    it('leaves a new message alone — nothing was answered', async () => {
      await composeAndSend({ type: 'new' });
      expect(mockSetFlag).not.toHaveBeenCalled();
    });

    it('leaves a forward alone — a forward does not answer anything', async () => {
      await composeAndSend({
        type: 'forward',
        reply_source: { folder: 'INBOX', id: 74 },
      });
      expect(mockSetFlag).not.toHaveBeenCalled();
    });

    it('sends normally when the reply has no source coordinates', async () => {
      // Reply opened from a surface that does not know the source uid: the
      // send must still complete, just without the flag.
      await composeAndSend({ type: 'reply' });
      expect(mockSetFlag).not.toHaveBeenCalled();
      expect(setMessage).toHaveBeenCalledWith('Email sent', false);
    });

    it('still reports the send as sent when flagging fails', async () => {
      mockSetFlag.mockRejectedValueOnce(new Error('nope'));
      await composeAndSend({
        type: 'reply',
        reply_source: { folder: 'INBOX', id: 74 },
      });
      expect(setMessage).toHaveBeenCalledWith('Email sent', false);
      expect(setMessage).not.toHaveBeenCalledWith('Error sending email', true);
    });
  });
});

import { render, screen, waitFor, act, fireEvent, within } from '@testing-library/react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import MessageOverlay from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

const RAW_EML = [
  'From: Alice Sender <sender@example.com>',
  'Subject: Test Subject',
  'Date: Thu, 17 Apr 2025 13:10:00 +0000',
  '',
  'Raw body line 1',
  'Raw body line 2',
].join('\r\n');

const mockGetMessage = vi.fn().mockResolvedValue({
  data: {
    message_body_plain: 'plain text body',
    message_body_html: '<p>html body</p>',
    message_raw: 'https://cache.example/signed',
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
const mockGetRawMessage = vi.fn().mockResolvedValue({ data: RAW_EML });

const mockApi = {
  getMessage: mockGetMessage,
  getAttachments: mockGetAttachments,
  getEnvelopes: mockGetEnvelopes,
  getAttachment: vi.fn().mockResolvedValue({ data: { url: 'http://dl.url' } }),
  getRawMessage: mockGetRawMessage,
  fetchImage: vi.fn().mockResolvedValue({ data: { url: 'http://img.url' } }),
  setFlag: vi.fn().mockResolvedValue({}),
  moveMessages: vi.fn().mockResolvedValue({}),
  purgeMessages: vi.fn().mockResolvedValue({}),
  getFolderList: vi.fn().mockResolvedValue({
    data: { folders: ['INBOX', 'Archive', 'qamove', 'Trash'], sub_folders: ['INBOX', 'Archive', 'qamove'] },
  }),
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

  it('shows inline retry card when message fetch fails', async () => {
    mockGetMessage.mockRejectedValueOnce(new Error('fail'));
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => {
        expect(screen.getByText(/Couldn.t load this message/i)).toBeInTheDocument();
      });
      expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('opens the View source modal and fetches raw text once', async () => {
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
      fireEvent.click(screen.getByLabelText('More actions'));
      fireEvent.click(screen.getByText('View source'));
      await waitFor(() => {
        expect(mockGetRawMessage).toHaveBeenCalledWith('https://cache.example/signed');
      });
      await waitFor(() => {
        expect(screen.getByRole('dialog', { name: 'Message source' })).toBeInTheDocument();
      });
    } finally {
      unmount();
    }
  });

  it('"Show original headers" opens the same modal pre-set to Headers', async () => {
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
      fireEvent.click(screen.getByLabelText('More actions'));
      fireEvent.click(screen.getByText('Show original headers'));
      await waitFor(() => {
        expect(screen.getByRole('dialog', { name: 'Message source' })).toBeInTheDocument();
      });
      expect(
        screen.getByRole('tab', { name: 'Headers' }).getAttribute('aria-selected'),
      ).toBe('true');
    } finally {
      unmount();
    }
  });

  it('closes the source modal when the reader is hidden, even for the same message', async () => {
    const { rerender, unmount } = renderOverlay();
    try {
      await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
      fireEvent.click(screen.getByLabelText('More actions'));
      fireEvent.click(screen.getByText('View source'));
      await waitFor(() => {
        expect(screen.getByRole('dialog', { name: 'Message source' })).toBeInTheDocument();
      });

      rerender(
        <AuthContext.Provider value={authValue}>
          <AppMessageContext.Provider value={{ setMessage }}>
            <MessageOverlay
              envelope={testEnvelope}
              folder="INBOX"
              visible={false}
              flags={['\\Seen']}
              hide={vi.fn()}
              updateOverlay={vi.fn()}
              reply={vi.fn()}
              replyAll={vi.fn()}
              forward={vi.fn()}
              readerFormat="rich"
              setReaderFormat={vi.fn()}
            />
          </AppMessageContext.Provider>
        </AuthContext.Provider>,
      );
      rerender(
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
              setReaderFormat={vi.fn()}
            />
          </AppMessageContext.Provider>
        </AuthContext.Provider>,
      );

      await waitFor(() => {
        expect(screen.getByText('Test Subject')).toBeInTheDocument();
      });
      expect(screen.queryByRole('dialog', { name: 'Message source' })).not.toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  // The reader is closed by an app-level Escape handler (useKeyboardShortcuts,
  // a document bubble listener). Anything the reader opens on top of itself has
  // to take Escape for itself, or one keypress closes two layers.
  describe('Escape inside the reader', () => {
    const pressEscape = () => {
      act(() => {
        document.body.dispatchEvent(
          new window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
        );
      });
    };

    it('does not reach the app-level handler while a layer is open', async () => {
      const behind = vi.fn();
      document.addEventListener('keydown', behind);
      const { container, unmount } = renderOverlay();
      try {
        await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());

        // Source modal.
        fireEvent.click(screen.getByLabelText('More actions'));
        fireEvent.click(screen.getByText('View source'));
        await waitFor(() => {
          expect(screen.getByRole('dialog', { name: 'Message source' })).toBeInTheDocument();
        });
        pressEscape();
        expect(screen.queryByRole('dialog', { name: 'Message source' })).not.toBeInTheDocument();

        // Overflow menu.
        fireEvent.click(screen.getByLabelText('More actions'));
        await waitFor(() => expect(screen.getByText('View source')).toBeInTheDocument());
        pressEscape();
        await waitFor(() => expect(screen.queryByText('View source')).not.toBeInTheDocument());

        // Move chooser.
        fireEvent.click(screen.getByLabelText('Move'));
        await waitFor(() => {
          expect(container.querySelector('.reader-move-picker select')).toBeTruthy();
        });
        pressEscape();
        await waitFor(() => {
          expect(container.querySelector('.reader-move-picker select')).toBeNull();
        });

        expect(behind).not.toHaveBeenCalled();

        // With nothing on top, Escape belongs to the reader again.
        pressEscape();
        expect(behind).toHaveBeenCalledTimes(1);
      } finally {
        document.removeEventListener('keydown', behind);
        unmount();
      }
    });
  });

  it('overflow menu exposes Archive, Block sender, Print', async () => {
    const { unmount } = renderOverlay();
    try {
      await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
      fireEvent.click(screen.getByLabelText('More actions'));
      expect(screen.getByText('Archive')).toBeInTheDocument();
      expect(screen.queryByText('Mark as spam')).not.toBeInTheDocument();
      expect(screen.getByText('Block sender')).toBeInTheDocument();
      expect(screen.getByText('Print…')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('Archive overflow item moves the message and hides the reader', async () => {
    const hide = vi.fn();
    const { unmount } = renderOverlay({ hide });
    try {
      await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
      fireEvent.click(screen.getByLabelText('More actions'));
      fireEvent.click(screen.getByText('Archive'));
      await waitFor(() => {
        expect(mockApi.moveMessages).toHaveBeenCalledWith(
          'INBOX', 'Archive', [1], '', expect.anything(),
        );
      });
      await waitFor(() => expect(hide).toHaveBeenCalled());
    } finally {
      unmount();
    }
  });

  describe('the Move button', () => {
    const pickerIn = (container) => container.querySelector('.reader-move-picker select');

    it('is enabled and opens a folder chooser', async () => {
      const { container, unmount } = renderOverlay();
      try {
        await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
        const moveButton = screen.getByLabelText('Move');
        expect(moveButton).not.toBeDisabled();
        fireEvent.click(moveButton);
        await waitFor(() => expect(pickerIn(container)).toBeTruthy());
        expect(within(pickerIn(container)).getByText('qamove')).toBeInTheDocument();
      } finally {
        unmount();
      }
    });

    it('moves the open message to the chosen folder and hides the reader', async () => {
      const hide = vi.fn();
      const { container, unmount } = renderOverlay({ hide });
      try {
        await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
        fireEvent.click(screen.getByLabelText('Move'));
        await waitFor(() => expect(pickerIn(container)).toBeTruthy());
        fireEvent.change(pickerIn(container), { target: { value: 'qamove' } });
        await waitFor(() => {
          expect(mockApi.moveMessages).toHaveBeenCalledWith(
            'INBOX', 'qamove', [1], '', expect.anything(),
          );
        });
        await waitFor(() => expect(hide).toHaveBeenCalled());
        expect(pickerIn(container)).toBeNull();
      } finally {
        unmount();
      }
    });

    it("does nothing when the message's own folder is chosen", async () => {
      const hide = vi.fn();
      const { container, unmount } = renderOverlay({ hide });
      try {
        await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
        fireEvent.click(screen.getByLabelText('Move'));
        await waitFor(() => expect(pickerIn(container)).toBeTruthy());
        fireEvent.change(pickerIn(container), { target: { value: 'INBOX' } });
        expect(mockApi.moveMessages).not.toHaveBeenCalled();
        expect(hide).not.toHaveBeenCalled();
      } finally {
        unmount();
      }
    });

    it('reports a failed move and keeps the reader open', async () => {
      const hide = vi.fn();
      mockApi.moveMessages.mockRejectedValueOnce(new Error('nope'));
      const { container, unmount } = renderOverlay({ hide });
      try {
        await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
        fireEvent.click(screen.getByLabelText('Move'));
        await waitFor(() => expect(pickerIn(container)).toBeTruthy());
        fireEvent.change(pickerIn(container), { target: { value: 'qamove' } });
        await waitFor(() => {
          expect(setMessage).toHaveBeenCalledWith(
            expect.stringContaining('Unable to move message'), true,
          );
        });
        expect(hide).not.toHaveBeenCalled();
      } finally {
        unmount();
      }
    });
  });

  describe('deleting from Trash', () => {
    it('confirms, purges, and hides instead of moving', async () => {
      const hide = vi.fn();
      const { unmount } = renderOverlay({ folder: 'Trash', hide });
      try {
        await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
        fireEvent.click(screen.getAllByLabelText('Delete forever')[0]);
        // Nothing happens until the dialog is confirmed.
        expect(mockApi.purgeMessages).not.toHaveBeenCalled();
        const dialog = screen.getByRole('alertdialog');
        fireEvent.click(within(dialog).getByRole('button', { name: /delete forever/i }));
        await waitFor(() => {
          expect(mockApi.purgeMessages).toHaveBeenCalledWith('Trash', [1]);
        });
        await waitFor(() => expect(hide).toHaveBeenCalled());
        expect(mockApi.moveMessages).not.toHaveBeenCalled();
      } finally {
        unmount();
      }
    });

    it('cancelling the confirmation leaves the message alone', async () => {
      const hide = vi.fn();
      const { unmount } = renderOverlay({ folder: 'Trash', hide });
      try {
        await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
        fireEvent.click(screen.getAllByLabelText('Delete forever')[0]);
        const dialog = screen.getByRole('alertdialog');
        fireEvent.click(within(dialog).getByRole('button', { name: /cancel/i }));
        expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
        expect(mockApi.purgeMessages).not.toHaveBeenCalled();
        expect(hide).not.toHaveBeenCalled();
      } finally {
        unmount();
      }
    });

    it('outside Trash, delete moves to Trash without confirmation', async () => {
      const hide = vi.fn();
      const { unmount } = renderOverlay({ hide });
      try {
        await waitFor(() => expect(mockGetMessage).toHaveBeenCalled());
        fireEvent.click(screen.getAllByLabelText('Delete')[0]);
        expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
        await waitFor(() => {
          expect(mockApi.moveMessages).toHaveBeenCalledWith(
            'INBOX', 'Trash', [1], '', expect.anything(),
          );
        });
        expect(mockApi.purgeMessages).not.toHaveBeenCalled();
      } finally {
        unmount();
      }
    });
  });

  describe('authentication line', () => {
    it('renders per-method chips colored by verdict for the warning state', async () => {
      const { unmount, container } = renderOverlay({
        envelope: {
          ...testEnvelope,
          auth_results: { spf: 'pass', dkim: 'fail', dmarc: 'fail' },
        },
      });
      try {
        await waitFor(() => expect(screen.getByText('Test Subject')).toBeInTheDocument());
        expect(container.querySelector('.reader-auth--warning')).toBeTruthy();
        const chips = container.querySelectorAll('.reader-auth-chip');
        expect(chips.length).toBe(3);
        expect(chips[0].className).toContain('reader-auth-chip--ok'); // SPF pass
        expect(chips[1].className).toContain('reader-auth-chip--bad'); // DKIM fail
        expect(chips[2].className).toContain('reader-auth-chip--bad'); // DMARC fail
        expect(chips[2].textContent).toContain('DMARC');
        expect(chips[2].textContent).toContain('fail');
        // Warning copy avoids "dangerous" framing.
        const line = container.querySelector('.reader-auth-line');
        expect(line.title).toContain('could not be authenticated as coming from its claimed sender');
      } finally {
        unmount();
      }
    });

    it('renders all three chips in the verified-ok state, with absent methods neutral', async () => {
      const { unmount, container } = renderOverlay({
        envelope: { ...testEnvelope, auth_results: { dkim: 'pass', dmarc: 'pass' } },
      });
      try {
        await waitFor(() => expect(screen.getByText('Test Subject')).toBeInTheDocument());
        expect(container.querySelector('.reader-auth--ok')).toBeTruthy();
        const chips = container.querySelectorAll('.reader-auth-chip');
        expect(chips.length).toBe(3);
        // SPF was not evaluated: neutral chip, no verdict token.
        expect(chips[0].className).toContain('reader-auth-chip--neutral');
        expect(chips[0].textContent).toContain('SPF');
      } finally {
        unmount();
      }
    });

    it('renders a muted "Not verified" when auth_results is absent — never a pass', async () => {
      const { unmount, container } = renderOverlay(); // testEnvelope has no auth_results
      try {
        await waitFor(() => expect(screen.getByText('Test Subject')).toBeInTheDocument());
        expect(container.querySelector('.reader-auth--not-verified')).toBeTruthy();
        expect(container.querySelectorAll('.reader-auth-chip').length).toBe(0);
        expect(screen.getByText('Not verified')).toBeInTheDocument();
      } finally {
        unmount();
      }
    });
  });
});

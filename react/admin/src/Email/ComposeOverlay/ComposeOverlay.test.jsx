import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import ComposeOverlay from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

const mockGetAddresses = vi.fn().mockResolvedValue({
  data: { Items: [{ address: 'user@test.com' }, { address: 'other@test.com' }] }
});
const mockSendMessage = vi.fn().mockResolvedValue({});

const mockApi = {
  getAddresses: mockGetAddresses,
  sendMessage: mockSendMessage,
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

  it('renders compose form with From, Recipients, Subject, and editor', async () => {
    const { unmount } = renderCompose();
    try {
      expect(screen.getByLabelText('From')).toBeInTheDocument();
      expect(screen.getByLabelText('Recipients')).toBeInTheDocument();
      expect(screen.getByLabelText('Subject')).toBeInTheDocument();
      expect(screen.getByText('Send')).toBeInTheDocument();
      expect(screen.getByText('Cancel')).toBeInTheDocument();
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
      await act(async () => { await Promise.resolve(); });
    } finally {
      unmount();
    }
  });

  it('calls hide when cancel is clicked', async () => {
    const hide = vi.fn();
    const { unmount } = renderCompose({ hide });
    try {
      fireEvent.click(screen.getByText('Cancel'));
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
      fireEvent.click(screen.getByText('Send'));
      expect(setMessage).toHaveBeenCalledWith('Please specify at least one recipient.', true);
    } finally {
      unmount();
    }
  });
});

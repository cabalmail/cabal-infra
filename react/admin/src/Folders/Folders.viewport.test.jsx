/* Phase 8 — viewport tests for the Folders drawer mode. */

import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Folders from './index';
import AuthContext from '../contexts/AuthContext';
import { setViewport, PHONE, DESKTOP } from '../test/viewport';

const mockGetFolderList = vi.fn();
const mockApi = {
  getFolderList: mockGetFolderList,
  subscribeFolder: vi.fn(),
  unsubscribeFolder: vi.fn(),
  deleteFolder: vi.fn(),
  newFolder: vi.fn(),
};

vi.mock('../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };

function renderFolders(props = {}) {
  return render(
    <AuthContext.Provider value={authValue}>
      <Folders
        folder="INBOX"
        setFolder={vi.fn()}
        setMessage={vi.fn()}
        onNewMessage={vi.fn()}
        {...props}
      />
    </AuthContext.Provider>,
  );
}

describe('Folders drawer (viewport)', () => {
  beforeEach(() => {
    mockGetFolderList.mockResolvedValue({
      data: { folders: ['INBOX'], sub_folders: [] },
    });
    localStorage.clear();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('renders drawer chrome (title + close) when asDrawer is true on phone', async () => {
    setViewport(...PHONE);
    renderFolders({ asDrawer: true, onClose: vi.fn() });
    await waitFor(() => expect(screen.getByText('Mailboxes')).toBeInTheDocument());
    expect(screen.getByRole('button', { name: /close navigation/i })).toBeInTheDocument();
  });

  it('does not render drawer chrome on desktop (asDrawer false)', async () => {
    setViewport(...DESKTOP);
    renderFolders({ asDrawer: false });
    await waitFor(() => expect(screen.getByText(/new message/i)).toBeInTheDocument());
    expect(screen.queryByText('Mailboxes')).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /close navigation/i })).not.toBeInTheDocument();
  });

  it('fires onClose when the drawer close button is clicked', async () => {
    setViewport(...PHONE);
    const onClose = vi.fn();
    renderFolders({ asDrawer: true, onClose });
    await waitFor(() => expect(screen.getByRole('button', { name: /close navigation/i })).toBeInTheDocument());
    fireEvent.click(screen.getByRole('button', { name: /close navigation/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});

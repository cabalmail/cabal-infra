import { render, screen, waitFor, fireEvent, act } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Folders from './index';
import AuthContext from '../contexts/AuthContext';

const mockGetFolderList = vi.fn();
const mockSubscribe = vi.fn();
const mockUnsubscribe = vi.fn();
const mockDeleteFolder = vi.fn();
const mockNewFolder = vi.fn();

const mockApi = {
  getFolderList: mockGetFolderList,
  subscribeFolder: mockSubscribe,
  unsubscribeFolder: mockUnsubscribe,
  deleteFolder: mockDeleteFolder,
  newFolder: mockNewFolder,
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
    </AuthContext.Provider>
  );
}

describe('Folders rail', () => {
  beforeEach(() => {
    mockGetFolderList.mockResolvedValue({
      data: {
        folders: ['INBOX', 'Drafts', 'Sent Messages', 'Archive', 'Deleted Messages', 'Junk', 'Receipts'],
        sub_folders: ['Receipts'],
      },
    });
    localStorage.clear();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('renders the New message CTA', async () => {
    renderFolders();
    expect(screen.getByRole('button', { name: /new message/i })).toBeInTheDocument();
  });

  it('renders the FOLDERS section label', async () => {
    renderFolders();
    expect(screen.getByText(/folders/i)).toBeInTheDocument();
  });

  it('renders system folders with their redesign display labels', async () => {
    renderFolders();
    await waitFor(() => expect(screen.getByText('Inbox')).toBeInTheDocument());
    expect(screen.getByText('Drafts')).toBeInTheDocument();
    expect(screen.getByText('Sent')).toBeInTheDocument();
    expect(screen.getByText('Archive')).toBeInTheDocument();
    expect(screen.getByText('Trash')).toBeInTheDocument();
    expect(screen.getByText('Junk')).toBeInTheDocument();
    // Receipts is subscribed in the fixture, so it appears in both the
    // Subscribed and All folders sections.
    expect(screen.getAllByText('Receipts').length).toBeGreaterThan(0);
  });

  it('marks the active folder with aria-current', async () => {
    renderFolders({ folder: 'INBOX' });
    await waitFor(() => expect(screen.getByText('Inbox')).toBeInTheDocument());
    const row = screen.getByText('Inbox').closest('li');
    expect(row).toHaveAttribute('aria-current', 'true');
    const drafts = screen.getByText('Drafts').closest('li');
    expect(drafts).not.toHaveAttribute('aria-current');
  });

  it('calls setFolder when a folder row is clicked', async () => {
    const setFolder = vi.fn();
    renderFolders({ setFolder });
    await waitFor(() => expect(screen.getByText('Drafts')).toBeInTheDocument());
    fireEvent.click(screen.getByText('Drafts').closest('li'));
    expect(setFolder).toHaveBeenCalledWith('Drafts');
  });

  it('calls onNewMessage when the New message button is clicked', async () => {
    const onNewMessage = vi.fn();
    renderFolders({ onNewMessage });
    fireEvent.click(screen.getByRole('button', { name: /new message/i }));
    expect(onNewMessage).toHaveBeenCalledTimes(1);
  });

  it('can delete a custom folder via the row remove action', async () => {
    mockDeleteFolder.mockResolvedValue({ data: { folders: [], sub_folders: [] } });
    renderFolders();
    await waitFor(() => expect(screen.getAllByText('Receipts').length).toBeGreaterThan(0));
    // Receipts is subscribed so it renders in both sections; either remove
    // button targets the same folder.
    const btns = screen.getAllByRole('button', { name: /remove receipts/i });
    await act(async () => { fireEvent.click(btns[0]); });
    expect(mockDeleteFolder).toHaveBeenCalledWith('Receipts');
  });

  it('never offers a remove action on permanent folders', async () => {
    renderFolders();
    await waitFor(() => expect(screen.getByText('Inbox')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: /remove inbox/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /remove drafts/i })).not.toBeInTheDocument();
  });

  it('toggles subscription from a folder row', async () => {
    mockUnsubscribe.mockResolvedValue({});
    renderFolders();
    await waitFor(() => expect(screen.getAllByText('Receipts').length).toBeGreaterThan(0));
    // Receipts is subscribed in the fixture, so it appears in both the
    // Subscribed and All folders sections. Either row's toggle is fine.
    const btns = screen.getAllByRole('button', { name: /unsubscribe from receipts/i });
    expect(btns.length).toBeGreaterThan(0);
    await act(async () => { fireEvent.click(btns[0]); });
    expect(mockUnsubscribe).toHaveBeenCalledWith('Receipts');
  });
});

import { render, screen, waitFor, fireEvent, act, within } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Folders from './index';
import AuthContext from '../contexts/AuthContext';

const mockGetFolderList = vi.fn();
const mockSubscribe = vi.fn();
const mockUnsubscribe = vi.fn();
const mockDeleteFolder = vi.fn();
const mockNewFolder = vi.fn();
const mockEmptyTrash = vi.fn();

const mockApi = {
  getFolderList: mockGetFolderList,
  subscribeFolder: mockSubscribe,
  unsubscribeFolder: mockUnsubscribe,
  deleteFolder: mockDeleteFolder,
  newFolder: mockNewFolder,
  emptyTrash: mockEmptyTrash,
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

  describe('empty trash', () => {
    it('offers Empty trash only on the trash row', async () => {
      renderFolders();
      await waitFor(() => expect(screen.getByText('Trash')).toBeInTheDocument());
      // One trash folder in the fixture, unsubscribed, so exactly one button.
      expect(screen.getAllByRole('button', { name: /empty trash/i })).toHaveLength(1);
      const trashRow = screen.getByText('Trash').closest('li');
      expect(within(trashRow).getByRole('button', { name: /empty trash/i })).toBeInTheDocument();
    });

    it('empties the trash after confirmation', async () => {
      mockEmptyTrash.mockResolvedValue({ data: { status: 'emptied' } });
      const setMessage = vi.fn();
      renderFolders({ setMessage });
      await waitFor(() => expect(screen.getByText('Trash')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: /empty trash/i }));
      // Nothing happens until the dialog is confirmed.
      expect(mockEmptyTrash).not.toHaveBeenCalled();
      const dialog = screen.getByRole('alertdialog');
      await act(async () => {
        fireEvent.click(within(dialog).getByRole('button', { name: /empty trash/i }));
      });
      expect(mockEmptyTrash).toHaveBeenCalledWith('Deleted Messages');
      await waitFor(() => expect(setMessage).toHaveBeenCalledWith('Trash emptied.', false));
    });

    it('does nothing when the confirmation is cancelled', async () => {
      renderFolders();
      await waitFor(() => expect(screen.getByText('Trash')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: /empty trash/i }));
      const dialog = screen.getByRole('alertdialog');
      fireEvent.click(within(dialog).getByRole('button', { name: /cancel/i }));
      expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
      expect(mockEmptyTrash).not.toHaveBeenCalled();
    });

    it('surfaces an error message when emptying fails', async () => {
      mockEmptyTrash.mockRejectedValue(new Error('boom'));
      const setMessage = vi.fn();
      renderFolders({ setMessage });
      await waitFor(() => expect(screen.getByText('Trash')).toBeInTheDocument());
      fireEvent.click(screen.getByRole('button', { name: /empty trash/i }));
      const dialog = screen.getByRole('alertdialog');
      await act(async () => {
        fireEvent.click(within(dialog).getByRole('button', { name: /empty trash/i }));
      });
      await waitFor(() => expect(setMessage).toHaveBeenCalledWith('Unable to empty trash.', true));
    });
  });

  describe('add folder', () => {
    it('creates a top-level folder via the section + button', async () => {
      mockNewFolder.mockResolvedValue({ data: { folders: [], sub_folders: [] } });
      renderFolders();
      await waitFor(() => expect(screen.getByText('Inbox')).toBeInTheDocument());
      // Both the section-header + icon and the bottom "New folder" row carry
      // the same accessible name; either opens the same input.
      const addBtns = screen.getAllByRole('button', { name: /^new folder$/i });
      await act(async () => { fireEvent.click(addBtns[0]); });
      const input = screen.getByPlaceholderText('New folder name');
      await act(async () => {
        fireEvent.change(input, { target: { value: 'Projects' } });
        fireEvent.keyDown(input, { key: 'Enter' });
      });
      expect(mockNewFolder).toHaveBeenCalledWith('', 'Projects');
    });

    it('creates a child folder via the per-row + action', async () => {
      mockGetFolderList.mockResolvedValue({
        data: {
          folders: ['INBOX', 'Work'],
          sub_folders: [],
        },
      });
      mockNewFolder.mockResolvedValue({ data: { folders: [], sub_folders: [] } });
      renderFolders({ folder: 'INBOX' });
      await waitFor(() => expect(screen.getByText('Work')).toBeInTheDocument());
      const addChildBtn = screen.getByRole('button', { name: /new folder inside work/i });
      await act(async () => { fireEvent.click(addChildBtn); });
      const input = screen.getByPlaceholderText('New folder name');
      await act(async () => {
        fireEvent.change(input, { target: { value: 'Q1' } });
        fireEvent.keyDown(input, { key: 'Enter' });
      });
      expect(mockNewFolder).toHaveBeenCalledWith('Work', 'Q1');
    });

    it('auto-expands a collapsed parent when adding a child under it', async () => {
      mockGetFolderList.mockResolvedValue({
        data: {
          folders: ['INBOX', 'Work', 'Work/Q1'],
          sub_folders: [],
        },
      });
      localStorage.setItem('folder_collapsed_paths', JSON.stringify(['Work']));
      renderFolders({ folder: 'INBOX' });
      await waitFor(() => expect(screen.getByText('Work')).toBeInTheDocument());
      expect(screen.queryByText('Q1')).not.toBeInTheDocument();
      const addChildBtn = screen.getByRole('button', { name: /new folder inside work/i });
      await act(async () => { fireEvent.click(addChildBtn); });
      // Parent expanded -> previously-hidden Q1 now visible, and the input renders inline.
      expect(screen.getByText('Q1')).toBeInTheDocument();
      expect(screen.getByPlaceholderText('New folder name')).toBeInTheDocument();
    });

    it('rejects names containing "." or "/" and surfaces a message', async () => {
      const setMessage = vi.fn();
      renderFolders({ setMessage });
      await waitFor(() => expect(screen.getByText('Inbox')).toBeInTheDocument());
      // Both the section-header + icon and the bottom "New folder" row carry
      // the same accessible name; either opens the same input.
      const addBtns = screen.getAllByRole('button', { name: /^new folder$/i });
      await act(async () => { fireEvent.click(addBtns[0]); });
      const input = screen.getByPlaceholderText('New folder name');
      await act(async () => {
        fireEvent.change(input, { target: { value: 'bad/name' } });
        fireEvent.keyDown(input, { key: 'Enter' });
      });
      expect(mockNewFolder).not.toHaveBeenCalled();
      expect(setMessage).toHaveBeenCalledWith(
        expect.stringContaining("must not contain"),
        true,
      );
    });
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

  describe('collapse persistence', () => {
    it('persists Subscribed/All section collapse to localStorage', async () => {
      const { unmount } = renderFolders();
      await waitFor(() => expect(screen.getByText('Inbox')).toBeInTheDocument());
      const subHeader = screen.getByText(/^Subscribed$/i).closest('[role="button"]');
      const allHeader = screen.getByText(/^All folders$/i).closest('[role="button"]');
      await act(async () => { fireEvent.click(subHeader); });
      await act(async () => { fireEvent.click(allHeader); });
      expect(localStorage.getItem('folder_collapsed_sub')).toBe('true');
      expect(localStorage.getItem('folder_collapsed_all')).toBe('true');
      unmount();
      renderFolders();
      await waitFor(() => {
        expect(
          screen.getByText(/^Subscribed$/i).closest('[role="button"]')
        ).toHaveAttribute('aria-expanded', 'false');
        expect(
          screen.getByText(/^All folders$/i).closest('[role="button"]')
        ).toHaveAttribute('aria-expanded', 'false');
      });
    });

    it('per-folder collapse hides descendants and persists', async () => {
      mockGetFolderList.mockResolvedValue({
        data: {
          folders: ['INBOX', 'Work', 'Work/Q1', 'Work/Q2'],
          sub_folders: [],
        },
      });
      const { unmount } = renderFolders({ folder: 'INBOX' });
      await waitFor(() => expect(screen.getByText('Work')).toBeInTheDocument());
      expect(screen.getByText('Q1')).toBeInTheDocument();
      expect(screen.getByText('Q2')).toBeInTheDocument();
      const collapseBtn = screen.getByRole('button', { name: /collapse work/i });
      await act(async () => { fireEvent.click(collapseBtn); });
      expect(screen.queryByText('Q1')).not.toBeInTheDocument();
      expect(screen.queryByText('Q2')).not.toBeInTheDocument();
      expect(JSON.parse(localStorage.getItem('folder_collapsed_paths'))).toEqual(['Work']);
      unmount();
      renderFolders({ folder: 'INBOX' });
      await waitFor(() => expect(screen.getByText('Work')).toBeInTheDocument());
      expect(screen.queryByText('Q1')).not.toBeInTheDocument();
    });

    it('auto-expands ancestors of the active selection', async () => {
      mockGetFolderList.mockResolvedValue({
        data: {
          folders: ['INBOX', 'Work', 'Work/Q1', 'Work/Q2'],
          sub_folders: [],
        },
      });
      localStorage.setItem('folder_collapsed_paths', JSON.stringify(['Work']));
      renderFolders({ folder: 'Work/Q1' });
      await waitFor(() => expect(screen.getByText('Q1')).toBeInTheDocument());
      expect(screen.getByText('Q2')).toBeInTheDocument();
      await waitFor(() => {
        expect(JSON.parse(localStorage.getItem('folder_collapsed_paths'))).toEqual([]);
      });
    });

    it('does not render a chevron on leaf folders', async () => {
      mockGetFolderList.mockResolvedValue({
        data: {
          folders: ['INBOX', 'Receipts'],
          sub_folders: [],
        },
      });
      renderFolders({ folder: 'INBOX' });
      await waitFor(() => expect(screen.getByText('Receipts')).toBeInTheDocument());
      expect(screen.queryByRole('button', { name: /collapse receipts/i })).not.toBeInTheDocument();
    });
  });
});

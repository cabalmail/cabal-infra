import { render, screen, waitFor, within, fireEvent, act } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Users from './index';
import AppMessageContext from '../contexts/AppMessageContext';

const mockListUsers = vi.fn();
const mockListAllAddresses = vi.fn();
const mockDeleteUser = vi.fn();
const mockUnassignAddress = vi.fn();

const mockApi = {
  listUsers: mockListUsers,
  listAllAddresses: mockListAllAddresses,
  deleteUser: mockDeleteUser,
  unassignAddress: mockUnassignAddress,
  confirmUser: vi.fn().mockResolvedValue({}),
  disableUser: vi.fn().mockResolvedValue({}),
  enableUser: vi.fn().mockResolvedValue({}),
  assignAddress: vi.fn().mockResolvedValue({}),
};

vi.mock('../hooks/useApi', () => ({
  default: () => mockApi,
}));

const SAMPLE_USERS = [
  { username: 'alice', status: 'CONFIRMED', enabled: true,  created: '2026-01-01T00:00:00Z' },
  { username: 'bob',   status: 'CONFIRMED', enabled: true,  created: '2026-01-02T00:00:00Z' },
];

const SAMPLE_ADDRESSES = [
  { address: 'alice@cabalmail.com', user: 'alice/bob' },
  { address: 'bob@cabalmail.com',   user: 'bob' },
];

function renderUsers() {
  return render(
    <AppMessageContext.Provider value={{ setMessage: vi.fn() }}>
      <Users />
    </AppMessageContext.Provider>
  );
}

function getDialog() {
  return screen.getByRole('alertdialog');
}

function getRowFor(username) {
  return screen.getByText(username).closest('.user-row');
}

describe('Users admin', () => {
  beforeEach(() => {
    mockListUsers.mockResolvedValue({ data: { Users: SAMPLE_USERS } });
    mockListAllAddresses.mockResolvedValue({ data: { Items: SAMPLE_ADDRESSES } });
    mockDeleteUser.mockResolvedValue({});
    mockUnassignAddress.mockResolvedValue({});
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('opens a confirmation dialog before deleting and deletes on confirm', async () => {
    renderUsers();
    await waitFor(() => expect(screen.getByText('alice')).toBeInTheDocument());
    const deleteBtn = getRowFor('alice').querySelector('button.delete');
    await act(async () => { fireEvent.click(deleteBtn); });
    expect(getDialog()).toBeInTheDocument();
    expect(within(getDialog()).getByText(/delete user\?/i)).toBeInTheDocument();
    expect(mockDeleteUser).not.toHaveBeenCalled();
    const confirmBtn = within(getDialog()).getByRole('button', { name: /^delete$/i });
    await act(async () => { fireEvent.click(confirmBtn); });
    expect(mockDeleteUser).toHaveBeenCalledWith('alice');
  });

  it('does not delete when the confirmation dialog is cancelled', async () => {
    renderUsers();
    await waitFor(() => expect(screen.getByText('alice')).toBeInTheDocument());
    const deleteBtn = getRowFor('alice').querySelector('button.delete');
    await act(async () => { fireEvent.click(deleteBtn); });
    expect(getDialog()).toBeInTheDocument();
    const cancelBtn = within(getDialog()).getByRole('button', { name: /^cancel$/i });
    await act(async () => { fireEvent.click(cancelBtn); });
    expect(mockDeleteUser).not.toHaveBeenCalled();
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
  });

  it('opens a confirmation dialog before unassigning a shared address', async () => {
    renderUsers();
    await waitFor(() => expect(screen.getByText('alice')).toBeInTheDocument());
    const aliceRowExt = screen.getByText('alice').closest('.user-row-extended');
    const removeBtn = within(aliceRowExt).getByTitle(/remove alice from alice@cabalmail\.com/i);
    await act(async () => { fireEvent.click(removeBtn); });
    expect(getDialog()).toBeInTheDocument();
    expect(within(getDialog()).getByText(/remove user from address\?/i)).toBeInTheDocument();
    expect(mockUnassignAddress).not.toHaveBeenCalled();
    const confirmBtn = within(getDialog()).getByRole('button', { name: /^remove$/i });
    await act(async () => { fireEvent.click(confirmBtn); });
    expect(mockUnassignAddress).toHaveBeenCalledWith('alice@cabalmail.com', 'alice');
  });

  it('does not unassign when the confirmation dialog is cancelled', async () => {
    renderUsers();
    await waitFor(() => expect(screen.getByText('alice')).toBeInTheDocument());
    const aliceRowExt = screen.getByText('alice').closest('.user-row-extended');
    const removeBtn = within(aliceRowExt).getByTitle(/remove alice from alice@cabalmail\.com/i);
    await act(async () => { fireEvent.click(removeBtn); });
    expect(getDialog()).toBeInTheDocument();
    const cancelBtn = within(getDialog()).getByRole('button', { name: /^cancel$/i });
    await act(async () => { fireEvent.click(cancelBtn); });
    expect(mockUnassignAddress).not.toHaveBeenCalled();
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
  });
});

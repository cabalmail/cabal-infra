import { render, screen, waitFor, fireEvent, act } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Rail from './Rail';
import AuthContext from '../contexts/AuthContext';

const mockGetAddresses = vi.fn();
const mockDeleteAddress = vi.fn();
const mockNewAddress = vi.fn();
const mockSetFavorite = vi.fn();
const mockListMyDomains = vi.fn();
const mockSuspendAddress = vi.fn();
const mockReinstateAddress = vi.fn();

const mockApi = {
  getAddresses: mockGetAddresses,
  invalidateAddressList: vi.fn(),
  deleteAddress: mockDeleteAddress,
  newAddress: mockNewAddress,
  setFavorite: mockSetFavorite,
  listMyDomains: mockListMyDomains,
  suspendAddress: mockSuspendAddress,
  reinstateAddress: mockReinstateAddress,
};

vi.mock('../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };

const SAMPLE_ADDRESSES = [
  { address: 'me@inbox.cabalmail.com',     subdomain: 'inbox',  tld: 'cabalmail.com', comment: 'Primary',   public_key: 'pk1' },
  { address: 'chris@main.cabalmail.com',   subdomain: 'main',   tld: 'cabalmail.com', comment: 'Work',      public_key: 'pk2' },
  { address: 'ops@team.cabalmail.com',     subdomain: 'team',   tld: 'cabalmail.com', comment: 'Alerts',    public_key: 'pk3' },
  { address: 'hello@public.cabalmail.com', subdomain: 'public', tld: 'cabalmail.com', comment: 'Business',  public_key: 'pk4' },
];

function renderAddresses(props = {}) {
  return render(
    <AuthContext.Provider value={authValue}>
      <Rail
        domains={[{ domain: 'cabalmail.com' }]}
        setMessage={vi.fn()}
        {...props}
      />
    </AuthContext.Provider>
  );
}

describe('Addresses rail', () => {
  beforeEach(() => {
    mockGetAddresses.mockResolvedValue({ data: { Items: SAMPLE_ADDRESSES } });
    mockSetFavorite.mockResolvedValue({});
    mockListMyDomains.mockResolvedValue({ data: { Domains: ['cabalmail.com'] } });
    localStorage.clear();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('renders the ADDRESSES section label', async () => {
    renderAddresses();
    expect(screen.getByText(/addresses/i)).toBeInTheDocument();
  });

  it('renders each address from the API', async () => {
    renderAddresses();
    await waitFor(() => expect(screen.getByText('me@inbox.cabalmail.com')).toBeInTheDocument());
    expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument();
    expect(screen.getByText('ops@team.cabalmail.com')).toBeInTheDocument();
    expect(screen.getByText('hello@public.cabalmail.com')).toBeInTheDocument();
  });

  it('filters the list with the filter input', async () => {
    renderAddresses();
    await waitFor(() => expect(screen.getByText('me@inbox.cabalmail.com')).toBeInTheDocument());
    fireEvent.change(screen.getByPlaceholderText(/filter addresses/i), { target: { value: 'chris' } });
    expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument();
    expect(screen.queryByText('me@inbox.cabalmail.com')).not.toBeInTheDocument();
  });

  it('copies the address to the clipboard when a row is clicked', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });
    const setMessage = vi.fn();
    renderAddresses({ setMessage });
    await waitFor(() => expect(screen.getByText('me@inbox.cabalmail.com')).toBeInTheDocument());
    await act(async () => {
      fireEvent.click(screen.getByText('me@inbox.cabalmail.com').closest('li'));
    });
    expect(writeText).toHaveBeenCalledWith('me@inbox.cabalmail.com');
    expect(setMessage).toHaveBeenCalledWith('Address copied to clipboard.', false);
  });

  it('copies the address when Enter is pressed on a focused row', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });
    renderAddresses();
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    await act(async () => {
      fireEvent.keyDown(
        screen.getByText('chris@main.cabalmail.com').closest('li'),
        { key: 'Enter' },
      );
    });
    expect(writeText).toHaveBeenCalledWith('chris@main.cabalmail.com');
  });

  it('reports a copy failure via setMessage', async () => {
    const writeText = vi.fn().mockRejectedValue(new Error('nope'));
    Object.assign(navigator, { clipboard: { writeText } });
    const setMessage = vi.fn();
    renderAddresses({ setMessage });
    await waitFor(() => expect(screen.getByText('me@inbox.cabalmail.com')).toBeInTheDocument());
    await act(async () => {
      fireEvent.click(screen.getByText('me@inbox.cabalmail.com').closest('li'));
    });
    expect(setMessage).toHaveBeenCalledWith('Failed to copy address.', true);
  });

  it('does not render a colored swatch for address rows', async () => {
    renderAddresses();
    await waitFor(() => expect(screen.getByText('me@inbox.cabalmail.com')).toBeInTheDocument());
    expect(document.querySelector('.addresses-rail__swatch')).toBeNull();
  });

  it('opens the request modal from the "+ New address" row', async () => {
    renderAddresses();
    await waitFor(() => expect(screen.getByText(/\+ New address/i)).toBeInTheDocument());
    fireEvent.click(screen.getByText(/\+ New address/i).closest('li'));
    expect(screen.getByText('New address')).toBeInTheDocument();
  });

  it('opens the request modal from the header "+" action', async () => {
    renderAddresses();
    fireEvent.click(screen.getByRole('button', { name: /^new address$/i }));
    expect(screen.getByText('New address')).toBeInTheDocument();
  });

  it('opens a confirmation dialog before revoking and revokes on confirm', async () => {
    mockDeleteAddress.mockResolvedValue({});
    renderAddresses();
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    const btn = screen.getByRole('button', { name: /revoke chris@main\.cabalmail\.com/i });
    await act(async () => { fireEvent.click(btn); });
    // Dialog open, no API call yet
    expect(screen.getByRole('alertdialog')).toBeInTheDocument();
    expect(screen.getByText(/revoke address\?/i)).toBeInTheDocument();
    expect(mockDeleteAddress).not.toHaveBeenCalled();
    // Confirm
    const confirmBtn = screen.getAllByRole('button', { name: /^revoke$/i })[0];
    await act(async () => { fireEvent.click(confirmBtn); });
    expect(mockDeleteAddress).toHaveBeenCalledWith(
      'chris@main.cabalmail.com',
      'main',
      'cabalmail.com',
      'pk2'
    );
  });

  it('toggles favorite via api.setFavorite and shows a Favorites section', async () => {
    renderAddresses();
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    const btn = screen.getByRole('button', { name: /favorite chris@main\.cabalmail\.com/i });
    await act(async () => { fireEvent.click(btn); });
    expect(mockSetFavorite).toHaveBeenCalledWith('chris@main.cabalmail.com', true);
    // After favoriting, both sections are shown (Favorites + All addresses).
    expect(screen.getByText('Favorites')).toBeInTheDocument();
    expect(screen.getByText('All addresses')).toBeInTheDocument();
  });

  it('seeds favorites from the API response favorite field', async () => {
    mockGetAddresses.mockResolvedValue({
      data: {
        Items: SAMPLE_ADDRESSES.map((a, i) => (
          i === 0 ? { ...a, favorite: true } : a
        )),
      },
    });
    renderAddresses();
    await waitFor(() => expect(screen.getByText('Favorites')).toBeInTheDocument());
    expect(screen.getByText('All addresses')).toBeInTheDocument();
  });

  it('opens a confirmation dialog before suspending and suspends on confirm', async () => {
    mockSuspendAddress.mockResolvedValue({});
    renderAddresses();
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    const btn = screen.getByRole('button', { name: /suspend chris@main\.cabalmail\.com/i });
    await act(async () => { fireEvent.click(btn); });
    // Dialog open, no API call yet
    expect(screen.getByRole('alertdialog')).toBeInTheDocument();
    expect(screen.getByText(/suspend address\?/i)).toBeInTheDocument();
    expect(mockSuspendAddress).not.toHaveBeenCalled();
    // Confirm
    const confirmBtn = screen.getAllByRole('button', { name: /^suspend$/i })[0];
    await act(async () => { fireEvent.click(confirmBtn); });
    expect(mockSuspendAddress).toHaveBeenCalledWith('chris@main.cabalmail.com');
    // The row flips to offering reinstate
    expect(screen.getByRole('button', { name: /reinstate chris@main\.cabalmail\.com/i }))
      .toBeInTheDocument();
  });

  it('does not suspend when the confirmation dialog is cancelled', async () => {
    mockSuspendAddress.mockResolvedValue({});
    renderAddresses();
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    const btn = screen.getByRole('button', { name: /suspend chris@main\.cabalmail\.com/i });
    await act(async () => { fireEvent.click(btn); });
    expect(screen.getByRole('alertdialog')).toBeInTheDocument();
    const cancelBtn = screen.getByRole('button', { name: /^cancel$/i });
    await act(async () => { fireEvent.click(cancelBtn); });
    expect(mockSuspendAddress).not.toHaveBeenCalled();
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
  });

  it('reinstates a suspended address directly, without a dialog', async () => {
    mockReinstateAddress.mockResolvedValue({});
    mockGetAddresses.mockResolvedValue({
      data: {
        Items: SAMPLE_ADDRESSES.map((a, i) => (
          i === 1 ? { ...a, suspended: true } : a
        )),
      },
    });
    renderAddresses();
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    const btn = screen.getByRole('button', { name: /reinstate chris@main\.cabalmail\.com/i });
    await act(async () => { fireEvent.click(btn); });
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
    expect(mockReinstateAddress).toHaveBeenCalledWith('chris@main.cabalmail.com');
    expect(screen.getByRole('button', { name: /suspend chris@main\.cabalmail\.com/i }))
      .toBeInTheDocument();
  });

  it('marks suspended rows with the is-suspended class', async () => {
    mockGetAddresses.mockResolvedValue({
      data: {
        Items: SAMPLE_ADDRESSES.map((a, i) => (
          i === 1 ? { ...a, suspended: true } : a
        )),
      },
    });
    renderAddresses();
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    expect(screen.getByText('chris@main.cabalmail.com').closest('li'))
      .toHaveClass('is-suspended');
    expect(screen.getByText('me@inbox.cabalmail.com').closest('li'))
      .not.toHaveClass('is-suspended');
  });

  it('does not revoke when the confirmation dialog is cancelled', async () => {
    mockDeleteAddress.mockResolvedValue({});
    renderAddresses();
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    const btn = screen.getByRole('button', { name: /revoke chris@main\.cabalmail\.com/i });
    await act(async () => { fireEvent.click(btn); });
    expect(screen.getByRole('alertdialog')).toBeInTheDocument();
    const cancelBtn = screen.getByRole('button', { name: /^cancel$/i });
    await act(async () => { fireEvent.click(cancelBtn); });
    expect(mockDeleteAddress).not.toHaveBeenCalled();
    expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument();
  });
});

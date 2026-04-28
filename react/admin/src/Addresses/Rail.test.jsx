import { render, screen, waitFor, fireEvent, act } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Rail from './Rail';
import AuthContext from '../contexts/AuthContext';

const mockGetAddresses = vi.fn();
const mockDeleteAddress = vi.fn();
const mockNewAddress = vi.fn();

const mockApi = {
  getAddresses: mockGetAddresses,
  deleteAddress: mockDeleteAddress,
  newAddress: mockNewAddress,
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
        selectedAddress={null}
        onSelectAddress={vi.fn()}
        {...props}
      />
    </AuthContext.Provider>
  );
}

describe('Addresses rail', () => {
  beforeEach(() => {
    mockGetAddresses.mockResolvedValue({ data: { Items: SAMPLE_ADDRESSES } });
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

  it('calls onSelectAddress when a row is clicked', async () => {
    const onSelectAddress = vi.fn();
    renderAddresses({ onSelectAddress });
    await waitFor(() => expect(screen.getByText('me@inbox.cabalmail.com')).toBeInTheDocument());
    fireEvent.click(screen.getByText('me@inbox.cabalmail.com').closest('li'));
    expect(onSelectAddress).toHaveBeenCalledWith('me@inbox.cabalmail.com');
  });

  it('marks the selected address with aria-current', async () => {
    renderAddresses({ selectedAddress: 'chris@main.cabalmail.com' });
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    const row = screen.getByText('chris@main.cabalmail.com').closest('li');
    expect(row).toHaveAttribute('aria-current', 'true');
  });

  it('toggles the filter off when the active address is clicked again', async () => {
    const onSelectAddress = vi.fn();
    renderAddresses({ selectedAddress: 'chris@main.cabalmail.com', onSelectAddress });
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    fireEvent.click(screen.getByText('chris@main.cabalmail.com').closest('li'));
    expect(onSelectAddress).toHaveBeenCalledWith(null);
  });

  it('does not render a colored swatch for address rows', async () => {
    renderAddresses();
    await waitFor(() => expect(screen.getByText('me@inbox.cabalmail.com')).toBeInTheDocument());
    expect(document.querySelector('.addresses-rail__swatch')).toBeNull();
  });

  it('copies an address to the clipboard via the row copy action', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });
    const setMessage = vi.fn();
    renderAddresses({ setMessage });
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    const btn = screen.getByRole('button', { name: /copy chris@main\.cabalmail\.com/i });
    await act(async () => { fireEvent.click(btn); });
    expect(writeText).toHaveBeenCalledWith('chris@main.cabalmail.com');
    expect(setMessage).toHaveBeenCalledWith('Address copied to clipboard.', false);
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

  it('revokes an address via the row remove action', async () => {
    mockDeleteAddress.mockResolvedValue({});
    renderAddresses();
    await waitFor(() => expect(screen.getByText('chris@main.cabalmail.com')).toBeInTheDocument());
    const btn = screen.getByRole('button', { name: /revoke chris@main\.cabalmail\.com/i });
    await act(async () => { fireEvent.click(btn); });
    expect(mockDeleteAddress).toHaveBeenCalledWith(
      'chris@main.cabalmail.com',
      'main',
      'cabalmail.com',
      'pk2'
    );
  });
});

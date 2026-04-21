import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import FromPicker from './index';

const FAVORITES_KEY = 'cabalmail.compose.favorites.v1';

const mockNewAddress = vi.fn();

vi.mock('../../../hooks/useApi', () => ({
  default: () => ({ newAddress: mockNewAddress }),
}));

const items = [
  { address: 'aa@test.com', comment: 'personal' },
  { address: 'bb@test.com', comment: 'work' },
  { address: 'cc@test.com' },
];

const domains = [{ domain: 'test.com' }, { domain: 'other.com' }];

function renderPicker(props = {}) {
  const onSelect = vi.fn();
  const onCreated = vi.fn();
  const setMessage = vi.fn();
  const utils = render(
    <FromPicker
      items={items}
      domains={domains}
      selected="aa@test.com"
      onSelect={onSelect}
      onCreated={onCreated}
      stackIndex={0}
      setMessage={setMessage}
      {...props}
    />
  );
  return { ...utils, onSelect, onCreated, setMessage };
}

describe('FromPicker', () => {
  beforeEach(() => {
    window.localStorage.clear();
    mockNewAddress.mockReset();
    mockNewAddress.mockResolvedValue({ data: { address: 'new@sub.test.com' } });
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('renders the selected address on the trigger', () => {
    const { unmount } = renderPicker();
    try {
      const trigger = document.getElementById('from-picker-trigger-0');
      expect(trigger).not.toBeNull();
      expect(trigger.textContent).toMatch(/aa@test\.com/);
    } finally {
      unmount();
    }
  });

  it('opens the menu and lists addresses when the trigger is clicked', async () => {
    const { unmount } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      expect(await screen.findByRole('listbox')).toBeInTheDocument();
      const options = screen.getAllByRole('option');
      expect(options.length).toBe(3);
    } finally {
      unmount();
    }
  });

  it('filters addresses via the search input', async () => {
    const { unmount } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      const search = await screen.findByLabelText('Search your addresses');
      fireEvent.change(search, { target: { value: 'work' } });
      await waitFor(() => {
        const options = screen.getAllByRole('option');
        expect(options.length).toBe(1);
        expect(options[0].textContent).toMatch(/bb@test\.com/);
      });
    } finally {
      unmount();
    }
  });

  it('shows "No address matches" when search has no results', async () => {
    const { unmount } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      const search = await screen.findByLabelText('Search your addresses');
      fireEvent.change(search, { target: { value: 'zzz' } });
      expect(await screen.findByText(/No address matches/)).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('calls onSelect and closes menu when an option is clicked', async () => {
    const { unmount, onSelect } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      const option = await screen.findByRole('option', { name: /bb@test\.com/ });
      fireEvent.click(option);
      expect(onSelect).toHaveBeenCalledWith('bb@test.com');
      await waitFor(() => {
        expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
      });
    } finally {
      unmount();
    }
  });

  it('toggles favorites and persists them to localStorage', async () => {
    const { unmount } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      const star = await screen.findByLabelText('Favorite bb@test.com');
      fireEvent.click(star);
      const stored = JSON.parse(window.localStorage.getItem(FAVORITES_KEY));
      expect(stored).toContain('bb@test.com');
      // After favoriting, a Favorites section should appear.
      expect(screen.getByText('Favorites')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('loads existing favorites from localStorage on mount', async () => {
    window.localStorage.setItem(FAVORITES_KEY, JSON.stringify(['cc@test.com']));
    const { unmount } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      expect(await screen.findByText('Favorites')).toBeInTheDocument();
      expect(screen.getByText('More addresses')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('keyboard navigation: ArrowDown + Enter picks the first option', async () => {
    const { unmount, onSelect } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      const search = await screen.findByLabelText('Search your addresses');
      fireEvent.keyDown(search, { key: 'ArrowDown' });
      fireEvent.keyDown(search, { key: 'Enter' });
      expect(onSelect).toHaveBeenCalledWith('aa@test.com');
    } finally {
      unmount();
    }
  });

  it('Escape closes the menu', async () => {
    const { unmount } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      const search = await screen.findByLabelText('Search your addresses');
      fireEvent.keyDown(search, { key: 'Escape' });
      await waitFor(() => {
        expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
      });
    } finally {
      unmount();
    }
  });

  it('opens inline Create form when "Create a new address" is clicked', async () => {
    const { unmount } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      const cta = await screen.findByText('Create a new address');
      fireEvent.click(cta);
      expect(await screen.findByLabelText('Username')).toBeInTheDocument();
      expect(screen.getByLabelText('Subdomain')).toBeInTheDocument();
      expect(screen.getByLabelText('Domain')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });

  it('submits the create form and calls onSelect + onCreated', async () => {
    const { unmount, onSelect, onCreated } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      const cta = await screen.findByText('Create a new address');
      fireEvent.click(cta);
      const userInput = await screen.findByLabelText('Username');
      fireEvent.change(userInput, { target: { value: 'newu' } });
      fireEvent.change(screen.getByLabelText('Subdomain'), { target: { value: 'sub' } });
      fireEvent.change(screen.getByLabelText('Domain'), { target: { value: 'test.com' } });
      const submit = screen.getByRole('button', { name: /Create & use/ });
      await act(async () => {
        fireEvent.click(submit);
      });
      expect(mockNewAddress).toHaveBeenCalledWith('newu', 'sub', 'test.com', '', 'newu@sub.test.com');
      expect(onSelect).toHaveBeenCalledWith('new@sub.test.com');
      expect(onCreated).toHaveBeenCalledWith('new@sub.test.com');
    } finally {
      unmount();
    }
  });

  it('disables Create & use until username, subdomain, and domain are all set', async () => {
    const { unmount } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      fireEvent.click(await screen.findByText('Create a new address'));
      const submit = await screen.findByRole('button', { name: /Create & use/ });
      expect(submit).toBeDisabled();
      fireEvent.change(screen.getByLabelText('Username'), { target: { value: 'u' } });
      expect(submit).toBeDisabled();
      fireEvent.change(screen.getByLabelText('Subdomain'), { target: { value: 's' } });
      expect(submit).toBeDisabled();
      fireEvent.change(screen.getByLabelText('Domain'), { target: { value: 'test.com' } });
      expect(submit).not.toBeDisabled();
    } finally {
      unmount();
    }
  });

  it('Cancel returns to the pick view', async () => {
    const { unmount } = renderPicker();
    try {
      fireEvent.click(document.getElementById('from-picker-trigger-0'));
      fireEvent.click(await screen.findByText('Create a new address'));
      const cancel = await screen.findByRole('button', { name: 'Cancel' });
      fireEvent.click(cancel);
      expect(await screen.findByLabelText('Search your addresses')).toBeInTheDocument();
    } finally {
      unmount();
    }
  });
});

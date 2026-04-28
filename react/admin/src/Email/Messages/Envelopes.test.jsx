import React, { useRef } from 'react';
import { render, act, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import Envelopes from './Envelopes';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

const mockGetEnvelopes = vi.fn();
const mockApi = { getEnvelopes: mockGetEnvelopes };
vi.mock('../../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };

function makeEnvelope(id, overrides = {}) {
  return {
    id: id.toString(),
    from: [`Sender ${id} <sender${id}@test.com>`],
    to: ['recipient@test.com'],
    cc: [],
    subject: `Subject ${id}`,
    date: new Date().toISOString(),
    flags: [],
    priority: '',
    struct: ['alternative', 'alternative'],
    ...overrides,
  };
}

function Harness({
  message_ids = [],
  selected = new Set(),
  bulkMode = false,
  filter = 'all',
  addressFilter = null,
  ...overrides
}) {
  const lastSelectedRef = useRef(null);
  const [sel, setSel] = React.useState(selected);
  const [bulk, setBulk] = React.useState(bulkMode);
  return (
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage: vi.fn() }}>
        <Envelopes
          message_ids={message_ids}
          folder="INBOX"
          showOverlay={vi.fn()}
          selected={sel}
          setSelected={setSel}
          lastSelectedRef={lastSelectedRef}
          bulkMode={bulk}
          setBulkMode={setBulk}
          filter={filter}
          addressFilter={addressFilter}
          markUnread={vi.fn()}
          markRead={vi.fn()}
          archive={vi.fn()}
          {...overrides}
        />
      </AppMessageContext.Provider>
    </AuthContext.Provider>
  );
}

describe('Envelopes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('fetches envelopes when message_ids are provided', async () => {
    const ids = [1, 2, 3];
    const envelopes = {};
    ids.forEach((id) => { envelopes[id.toString()] = makeEnvelope(id); });
    mockGetEnvelopes.mockResolvedValue({ data: { envelopes } });

    render(<Harness message_ids={ids} />);

    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    expect(mockGetEnvelopes).toHaveBeenCalledWith('INBOX', ids);
  });

  it('handles concurrent page fetches without race conditions', async () => {
    const ids = Array.from({ length: 60 }, (_, i) => i + 1);

    const page1 = {};
    ids.slice(0, 30).forEach((id) => { page1[id.toString()] = makeEnvelope(id); });
    const page2 = {};
    ids.slice(30, 60).forEach((id) => { page2[id.toString()] = makeEnvelope(id); });

    let resolvePage1;
    const page1Promise = new Promise((resolve) => { resolvePage1 = resolve; });

    mockGetEnvelopes
      .mockImplementationOnce(() => page1Promise)
      .mockImplementationOnce(() => Promise.resolve({ data: { envelopes: page2 } }));

    render(<Harness message_ids={ids} />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    await act(async () => {
      resolvePage1({ data: { envelopes: page1 } });
      await new Promise((r) => setTimeout(r, 0));
    });

    expect(mockGetEnvelopes).toHaveBeenCalledTimes(2);
  });

  it('renders the empty-state hint when nothing matches the filter', async () => {
    mockGetEnvelopes.mockResolvedValue({ data: { envelopes: {} } });
    const { container } = render(
      <Harness message_ids={[]} filter="unread" emptyLabel="No unread messages." />,
    );
    expect(container.querySelector('.envelopes-empty')).toBeTruthy();
    expect(container.textContent).toContain('No unread messages.');
    expect(container.textContent).toContain('Clear filter');
  });

  it('filters by flagged / unread', async () => {
    const envelopes = {
      '1': makeEnvelope(1, { flags: [] }),                     // unread
      '2': makeEnvelope(2, { flags: ['\\Seen'] }),             // read
      '3': makeEnvelope(3, { flags: ['\\Seen', '\\Flagged'] }) // read, flagged
    };
    mockGetEnvelopes.mockResolvedValue({ data: { envelopes } });

    const { container, rerender } = render(
      <Harness message_ids={[1, 2, 3]} filter="flagged" />,
    );
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    expect(container.querySelectorAll('.envelope-row').length).toBe(1);

    rerender(
      <Harness message_ids={[1, 2, 3]} filter="unread" />,
    );
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    expect(container.querySelectorAll('.envelope-row').length).toBe(1);
  });

  it('toggles selection and triggers bulk mode on click', async () => {
    const envelopes = {
      '1': makeEnvelope(1),
      '2': makeEnvelope(2),
    };
    mockGetEnvelopes.mockResolvedValue({ data: { envelopes } });

    const { container } = render(<Harness message_ids={[1, 2]} />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    const leading = container.querySelectorAll('.envelope-leading');
    expect(leading.length).toBe(2);

    fireEvent.click(leading[0]);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    // After toggle, first row should be checked.
    expect(container.querySelectorAll('.envelope-row.checked').length).toBe(1);
    // And bulk mode kicks on.
    expect(container.querySelector('.envelope-list.bulk-mode')).toBeTruthy();
  });

  it('shift-clicking range-selects contiguous rows', async () => {
    const ids = [1, 2, 3, 4, 5];
    const envelopes = {};
    ids.forEach((id) => { envelopes[id.toString()] = makeEnvelope(id); });
    mockGetEnvelopes.mockResolvedValue({ data: { envelopes } });

    const { container } = render(<Harness message_ids={ids} />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    const leading = container.querySelectorAll('.envelope-leading');
    // Select row 1 first.
    fireEvent.click(leading[0]);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    // Shift-click row 4 — should select 1..4.
    fireEvent.click(leading[3], { shiftKey: true });
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    expect(container.querySelectorAll('.envelope-row.checked').length).toBe(4);
  });
});

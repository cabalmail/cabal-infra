import React from 'react';
import { render, screen, act, fireEvent, waitFor } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import Search from './index';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

const mockSearchEnvelopes = vi.fn();
const mockSetFlag = vi.fn();
const mockMoveMessages = vi.fn();
const mockApi = {
  searchEnvelopes: mockSearchEnvelopes,
  setFlag: mockSetFlag,
  moveMessages: mockMoveMessages,
};
vi.mock('../../hooks/useApi', () => ({ default: () => mockApi }));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };

function makeEnvelope(id, overrides = {}) {
  return {
    id: id.toString(),
    from: [`Sender ${id} <s${id}@test.com>`],
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

function Harness({ query = 'hello', folder = 'INBOX', clearSearch = vi.fn() }) {
  const [selected, setSelected] = React.useState(() => new Set());
  const [bulkMode, setBulkMode] = React.useState(false);
  const setMessage = vi.fn();
  return (
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage }}>
        <Search
          folder={folder}
          query={query}
          clearSearch={clearSearch}
          showOverlay={vi.fn()}
          selected={selected}
          setSelected={setSelected}
          bulkMode={bulkMode}
          setBulkMode={setBulkMode}
          layout="desktop"
        />
      </AppMessageContext.Provider>
    </AuthContext.Provider>
  );
}

describe('Search results pane', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockSearchEnvelopes.mockResolvedValue({
      data: {
        envelopes: [makeEnvelope(1), makeEnvelope(2)],
        total_estimate: 2,
        next_cursor: null,
        truncated: false,
        folders_searched: ['INBOX'],
      },
    });
    mockSetFlag.mockResolvedValue({ data: { ok: true } });
    mockMoveMessages.mockResolvedValue({ data: { ok: true } });
  });

  it('calls /search_envelopes cross-folder by default (no folder param)', async () => {
    render(<Harness query="invoices" folder="INBOX" />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    expect(mockSearchEnvelopes).toHaveBeenCalledTimes(1);
    const params = mockSearchEnvelopes.mock.calls[0][0];
    expect(params).toMatchObject({ text: 'invoices', limit: 50 });
    expect(params.folder).toBeUndefined();
  });

  it('scopes the search to the current folder when "This folder only" is checked', async () => {
    render(<Harness query="invoices" folder="INBOX" />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    fireEvent.click(screen.getByRole('button', { name: /filters/i }));
    const check = screen.getByLabelText('This folder only');
    fireEvent.click(check);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    expect(mockSearchEnvelopes).toHaveBeenCalledTimes(2);
    expect(mockSearchEnvelopes.mock.calls[1][0]).toMatchObject({
      folder: 'INBOX',
      text: 'invoices',
    });
  });

  it('renders one envelope row per result envelope', async () => {
    const { container } = render(<Harness query="hello" />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    expect(container.querySelectorAll('.envelope-row').length).toBe(2);
    expect(container.textContent).toContain('2 of 2');
  });

  it('shows the empty state when no envelopes match', async () => {
    mockSearchEnvelopes.mockResolvedValueOnce({
      data: { envelopes: [], total_estimate: 0, next_cursor: null, truncated: false, folders_searched: ['INBOX'] },
    });
    const { container } = render(<Harness query="nope" />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    expect(container.querySelector('.search-empty')).toBeTruthy();
    expect(container.textContent).toContain('No messages match');
  });

  it('surfaces the truncation hint when the cap was hit', async () => {
    mockSearchEnvelopes.mockResolvedValueOnce({
      data: {
        envelopes: [makeEnvelope(1)],
        total_estimate: 5000,
        next_cursor: 'next-token',
        truncated: true,
        folders_searched: ['INBOX'],
      },
    });
    const { container } = render(<Harness query="hit-cap" />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    expect(container.textContent).toMatch(/refine your query/i);
  });

  it('paginates via the next_cursor on Load more', async () => {
    mockSearchEnvelopes
      .mockResolvedValueOnce({
        data: {
          envelopes: [makeEnvelope(1)],
          total_estimate: 2,
          next_cursor: 'page-2',
          truncated: false,
          folders_searched: ['INBOX'],
        },
      })
      .mockResolvedValueOnce({
        data: {
          envelopes: [makeEnvelope(2)],
          total_estimate: 2,
          next_cursor: null,
          truncated: false,
          folders_searched: ['INBOX'],
        },
      });

    const { container } = render(<Harness query="paged" />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    expect(container.querySelectorAll('.envelope-row').length).toBe(1);

    const more = screen.getByRole('button', { name: /load more/i });
    fireEvent.click(more);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    expect(mockSearchEnvelopes).toHaveBeenCalledTimes(2);
    expect(mockSearchEnvelopes.mock.calls[1][0]).toMatchObject({ cursor: 'page-2' });
    expect(container.querySelectorAll('.envelope-row').length).toBe(2);
  });

  it('opening the filter panel and applying a filter re-runs the search with that param', async () => {
    render(<Harness query="meeting" />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    expect(mockSearchEnvelopes).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByRole('button', { name: /filters/i }));
    const from = screen.getByPlaceholderText('sender@example.com');
    fireEvent.change(from, { target: { value: 'alice@example.com' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    expect(mockSearchEnvelopes).toHaveBeenCalledTimes(2);
    expect(mockSearchEnvelopes.mock.calls[1][0]).toMatchObject({
      text: 'meeting',
      from: 'alice@example.com',
    });
    // Cross-folder default — folder is omitted.
    expect(mockSearchEnvelopes.mock.calls[1][0].folder).toBeUndefined();
  });

  it('routes single-row archive to the envelope\'s source folder, not the page folder', async () => {
    mockSearchEnvelopes.mockResolvedValueOnce({
      data: {
        envelopes: [makeEnvelope(7, { folder: 'Archive/2024' })],
        total_estimate: 1,
        next_cursor: null,
        truncated: false,
        folders_searched: ['INBOX', 'Archive/2024'],
      },
    });
    render(<Harness query="receipt" folder="INBOX" />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    // The Envelope row exposes archive via a swipe action; tap it.
    fireEvent.click(screen.getByText('Archive'));
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    expect(mockMoveMessages).toHaveBeenCalled();
    const [src, dest] = mockMoveMessages.mock.calls[0];
    expect(src).toBe('Archive/2024');
    expect(dest).toBe('Archive');
  });

  it('groups bulk move calls by each selected envelope\'s source folder', async () => {
    mockSearchEnvelopes.mockResolvedValueOnce({
      data: {
        envelopes: [
          makeEnvelope(1, { folder: 'INBOX' }),
          makeEnvelope(2, { folder: 'Archive/2024' }),
          makeEnvelope(3, { folder: 'INBOX' }),
        ],
        total_estimate: 3,
        next_cursor: null,
        truncated: false,
        folders_searched: ['INBOX', 'Archive/2024'],
      },
    });

    const { container } = render(<Harness query="receipt" folder="INBOX" />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    // Pick all three rows via the row checkbox; Search auto-flips into
    // bulk mode on first selection. Selection state lives in Harness,
    // so the clear-on-mount effect runs once before this.
    const leadings = container.querySelectorAll('.envelope-leading');
    expect(leadings.length).toBe(3);
    fireEvent.click(leadings[0]);
    fireEvent.click(leadings[1]);
    fireEvent.click(leadings[2]);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    fireEvent.click(screen.getByRole('button', { name: /^Archive$/i }));
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });

    expect(mockMoveMessages).toHaveBeenCalledTimes(2);
    const byFolder = Object.fromEntries(
      mockMoveMessages.mock.calls.map(([src, dest, ids]) => [src, { dest, ids: ids.slice().sort() }]),
    );
    expect(byFolder['INBOX']).toEqual({ dest: 'Archive', ids: [1, 3] });
    expect(byFolder['Archive/2024']).toEqual({ dest: 'Archive', ids: [2] });
  });

  it('Clear button invokes clearSearch', async () => {
    const clearSearch = vi.fn();
    render(<Harness query="anything" clearSearch={clearSearch} />);
    await act(async () => { await new Promise((r) => setTimeout(r, 0)); });
    fireEvent.click(screen.getByRole('button', { name: /clear search/i }));
    expect(clearSearch).toHaveBeenCalled();
  });

  it('renders the failure state when the API rejects', async () => {
    mockSearchEnvelopes.mockRejectedValueOnce(new Error('boom'));
    const { container } = render(<Harness query="fail" />);
    await waitFor(() => {
      expect(container.querySelector('.search-empty[role="alert"]')).toBeTruthy();
    });
    expect(container.textContent).toMatch(/Search failed/i);
  });
});

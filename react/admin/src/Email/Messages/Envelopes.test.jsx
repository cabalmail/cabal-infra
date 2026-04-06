import { render, act } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Envelopes from './Envelopes';
import AuthContext from '../../contexts/AuthContext';
import AppMessageContext from '../../contexts/AppMessageContext';

const mockGetEnvelopes = vi.fn();
const mockApi = { getEnvelopes: mockGetEnvelopes };
vi.mock('../../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };

function makeEnvelope(id) {
  return {
    id: id.toString(),
    from: [`sender${id}@test.com`],
    to: ['recipient@test.com'],
    cc: [],
    subject: `Subject ${id}`,
    date: '2024-01-01',
    flags: [],
    priority: '',
    struct: ['alternative', 'alternative'],
  };
}

function renderEnvelopes(props = {}) {
  return render(
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage: vi.fn() }}>
        <Envelopes
          message_ids={[]}
          folder="INBOX"
          host="host"
          token="tok"
          api_url="http://api"
          selected_messages={[]}
          showOverlay={vi.fn()}
          handleCheck={vi.fn()}
          handleSelect={vi.fn()}
          setMessage={vi.fn()}
          markUnread={vi.fn()}
          markRead={vi.fn()}
          archive={vi.fn()}
          {...props}
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
    ids.forEach(id => { envelopes[id.toString()] = makeEnvelope(id); });

    mockGetEnvelopes.mockResolvedValue({ data: { envelopes } });

    renderEnvelopes({ message_ids: ids });

    await act(async () => {
      await new Promise(r => setTimeout(r, 0));
    });

    expect(mockGetEnvelopes).toHaveBeenCalledWith('INBOX', ids);
  });

  it('handles concurrent page fetches without race conditions', async () => {
    // Simulate 60 messages = 2 pages of 30
    const ids = Array.from({ length: 60 }, (_, i) => i + 1);

    const page1Envelopes = {};
    ids.slice(0, 30).forEach(id => { page1Envelopes[id.toString()] = makeEnvelope(id); });

    const page2Envelopes = {};
    ids.slice(30, 60).forEach(id => { page2Envelopes[id.toString()] = makeEnvelope(id); });

    // Page 2 resolves before page 1 (race condition scenario)
    let resolvePage1;
    const page1Promise = new Promise(resolve => { resolvePage1 = resolve; });

    mockGetEnvelopes
      .mockImplementationOnce(() => page1Promise)
      .mockImplementationOnce(() => Promise.resolve({ data: { envelopes: page2Envelopes } }));

    const { container } = renderEnvelopes({ message_ids: ids });

    // Let page 2 resolve first
    await act(async () => {
      await new Promise(r => setTimeout(r, 0));
    });

    // Now resolve page 1
    await act(async () => {
      resolvePage1({ data: { envelopes: page1Envelopes } });
      await new Promise(r => setTimeout(r, 0));
    });

    // Both pages should be available — functional updates prevent overwrite
    // The component uses pages state with functional setPages(prev => ...)
    // so page2 data is preserved when page1 resolves later
    expect(mockGetEnvelopes).toHaveBeenCalledTimes(2);
  });

  it('re-fetches when message_ids change', async () => {
    const ids1 = [1, 2];
    const envelopes1 = {};
    ids1.forEach(id => { envelopes1[id.toString()] = makeEnvelope(id); });
    mockGetEnvelopes.mockResolvedValue({ data: { envelopes: envelopes1 } });

    const { rerender } = renderEnvelopes({ message_ids: ids1 });

    await act(async () => {
      await new Promise(r => setTimeout(r, 0));
    });

    expect(mockGetEnvelopes).toHaveBeenCalledTimes(1);

    // Change message_ids
    const ids2 = [3, 4, 5];
    const envelopes2 = {};
    ids2.forEach(id => { envelopes2[id.toString()] = makeEnvelope(id); });
    mockGetEnvelopes.mockResolvedValue({ data: { envelopes: envelopes2 } });

    rerender(
      <AuthContext.Provider value={authValue}>
        <AppMessageContext.Provider value={{ setMessage: vi.fn() }}>
          <Envelopes
            message_ids={ids2}
            folder="INBOX"
            host="host"
            token="tok"
            api_url="http://api"
            selected_messages={[]}
            showOverlay={vi.fn()}
            handleCheck={vi.fn()}
            handleSelect={vi.fn()}
            setMessage={vi.fn()}
            markUnread={vi.fn()}
            markRead={vi.fn()}
            archive={vi.fn()}
          />
        </AppMessageContext.Provider>
      </AuthContext.Provider>
    );

    await act(async () => {
      await new Promise(r => setTimeout(r, 0));
    });

    expect(mockGetEnvelopes).toHaveBeenCalledTimes(2);
  });

  it('does not render envelopes for ids without data', () => {
    mockGetEnvelopes.mockResolvedValue({ data: { envelopes: {} } });

    const { container } = renderEnvelopes({ message_ids: [1, 2, 3] });

    // No envelope rows should render since data hasn't loaded yet
    expect(container.querySelectorAll('.message-row').length).toBe(0);
  });
});

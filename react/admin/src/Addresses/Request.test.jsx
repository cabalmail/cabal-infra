import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import Request from './Request';
import AuthContext from '../contexts/AuthContext';

const mockNewAddress = vi.fn();
const mockListMyDomains = vi.fn();

const mockApi = {
  newAddress: mockNewAddress,
  listMyDomains: mockListMyDomains,
};

vi.mock('../hooks/useApi', () => ({
  default: () => mockApi,
}));

const authValue = { token: 'tok', api_url: 'http://api', host: 'host' };

function renderRequest(props = {}) {
  const setMessage = props.setMessage || vi.fn();
  const callback = props.callback || vi.fn();
  const utils = render(
    <AuthContext.Provider value={authValue}>
      <Request
        domains={[{ domain: 'cabalmail.com' }]}
        setMessage={setMessage}
        callback={callback}
      />
    </AuthContext.Provider>
  );
  return { ...utils, setMessage, callback };
}

function fillForm({ domain } = {}) {
  fireEvent.change(screen.getByPlaceholderText('username'), { target: { name: 'username', value: 'qa0801' } });
  fireEvent.change(screen.getByPlaceholderText('subdomain'), { target: { name: 'subdomain', value: 'probe0801' } });
  fireEvent.change(screen.getByPlaceholderText('optional note'), { target: { name: 'comment', value: 'probe note' } });
  if (domain) {
    fireEvent.change(screen.getByRole('combobox'), { target: { name: 'domain', value: domain } });
  }
}

function expectFormValues({ username, subdomain, comment }) {
  expect(screen.getByPlaceholderText('username').value).toBe(username);
  expect(screen.getByPlaceholderText('subdomain').value).toBe(subdomain);
  expect(screen.getByPlaceholderText('optional note').value).toBe(comment);
}

describe('Address request form', () => {
  beforeEach(() => {
    mockListMyDomains.mockResolvedValue({ data: { Domains: ['cabalmail.com'] } });
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it('refuses to submit without a domain, keeps the typed input and says why', async () => {
    const { setMessage } = renderRequest();
    await waitFor(() => expect(screen.getByRole('option', { name: 'cabalmail.com' })).toBeTruthy());

    fillForm();
    fireEvent.click(screen.getByRole('button', { name: /^Request/ }));

    expect(mockNewAddress).not.toHaveBeenCalled();
    expect(setMessage).toHaveBeenCalledWith(expect.stringContaining('a domain'), true);
    expectFormValues({ username: 'qa0801', subdomain: 'probe0801', comment: 'probe note' });
  });

  it('submits and clears the form once the domain is picked', async () => {
    mockNewAddress.mockResolvedValue({ data: { address: 'qa0801@probe0801.cabalmail.com' } });
    const { setMessage, callback } = renderRequest();
    await waitFor(() => expect(screen.getByRole('option', { name: 'cabalmail.com' })).toBeTruthy());

    fillForm({ domain: 'cabalmail.com' });
    fireEvent.click(screen.getByRole('button', { name: /^Request/ }));

    await waitFor(() => expect(callback).toHaveBeenCalledWith('qa0801@probe0801.cabalmail.com'));
    expect(mockNewAddress).toHaveBeenCalledWith(
      'qa0801', 'probe0801', 'cabalmail.com', 'probe note', 'qa0801@probe0801.cabalmail.com'
    );
    expect(setMessage).toHaveBeenCalledWith(expect.stringContaining('Successfully requested'), false);
    expectFormValues({ username: '', subdomain: '', comment: '' });
  });

  it('reports a rejected request and keeps the typed input', async () => {
    mockNewAddress.mockRejectedValue({ response: { data: { message: 'Address already exists' } } });
    const { setMessage, callback } = renderRequest();
    await waitFor(() => expect(screen.getByRole('option', { name: 'cabalmail.com' })).toBeTruthy());

    fillForm({ domain: 'cabalmail.com' });
    fireEvent.click(screen.getByRole('button', { name: /^Request/ }));

    await waitFor(() => expect(setMessage).toHaveBeenCalledWith(
      expect.stringContaining('Address already exists'), true
    ));
    expect(callback).not.toHaveBeenCalled();
    expectFormValues({ username: 'qa0801', subdomain: 'probe0801', comment: 'probe note' });
  });
});

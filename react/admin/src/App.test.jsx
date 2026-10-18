import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import axios from 'axios';
import App from './App';
import { SESSION_STORAGE_KEY } from './auth';
import { makeJwt, reply, cognitoError } from './test/cognito';

// App drives the real auth screens against a stubbed Cognito: fetch is
// routed by X-Amz-Target to per-operation reply queues, so each test says
// exactly which calls it expects and an unexpected one fails it. axios
// serves /config.js and answers every API call with an empty body. The
// views behind sign-in are stubbed down to what the tests read.

vi.mock('axios', () => {
  const ok = () => Promise.resolve({ data: {} });
  return {
    default: {
      get: vi.fn(),
      put: vi.fn(ok),
      post: vi.fn(ok),
      delete: vi.fn(ok),
      interceptors: { response: { use: vi.fn(() => 1), eject: vi.fn() } },
    },
  };
});

vi.mock('./Email', () => ({
  default: ({ token }) => <div data-testid="email-view">{token}</div>,
}));

vi.mock('./Nav', () => ({
  default: ({ isAdmin, doLogout, onClick }) => (
    <nav>
      <span data-testid="is-admin">{String(isAdmin)}</span>
      <button type="button" name="Security" onClick={onClick}>Security</button>
      <button type="button" onClick={doLogout}>Log out</button>
    </nav>
  ),
}));

const CONFIG = {
  control_domain: 'example.test',
  domains: {},
  invitation_required: true,
  sms_enabled: false,
  monitoring: false,
  cognitoConfig: {
    region: 'us-east-1',
    poolData: { UserPoolId: 'us-east-1_pool', ClientId: 'main-client' },
    enrollClientId: 'enroll-client',
  },
};

const PLAIN_ID = makeJwt({ 'cognito:username': 'alice' });
const ADMIN_ID = makeJwt({ 'cognito:username': 'alice', 'cognito:groups': ['admin'] });

function auth(idToken = PLAIN_ID, { expiresIn = 43200, refreshToken = 'refresh-1', accessToken = 'access-1' } = {}) {
  return reply(200, {
    AuthenticationResult: {
      IdToken: idToken, AccessToken: accessToken, RefreshToken: refreshToken, ExpiresIn: expiresIn,
    },
  });
}

function user({ email = 'alice@example.com', verified = true, mfa = ['SOFTWARE_TOKEN_MFA'] } = {}) {
  const attributes = email ? [
    { Name: 'email', Value: email },
    { Name: 'email_verified', Value: verified ? 'true' : 'false' },
  ] : [];
  return reply(200, { Username: 'alice', UserAttributes: attributes, UserMFASettingList: mfa });
}

const TOTP_CHALLENGE = reply(200, {
  ChallengeName: 'SOFTWARE_TOKEN_MFA',
  Session: 'challenge-session',
  ChallengeParameters: { USER_ID_FOR_SRP: 'alice' },
});

const MFA_REFUSAL = cognitoError(400, 'UserLambdaValidationException',
  'PreTokenGeneration failed with error This account requires multi-factor authentication. '
  + 'Sign in on the web app to set up an authenticator, then try again.');

let routes;
let calls;

function cognito(replies) {
  routes = {};
  Object.entries(replies).forEach(([op, list]) => { routes[op] = [...list]; });
}

/** The bodies sent to one Cognito operation, in order. */
function sentTo(op) {
  return calls.filter((c) => c.op === op).map((c) => c.body);
}

beforeEach(() => {
  window.localStorage.clear();
  window.sessionStorage.clear();
  calls = [];
  routes = {};
  axios.get.mockImplementation((url) => (
    url === '/config.js' ? Promise.resolve({ data: CONFIG }) : Promise.resolve({ data: {} })
  ));
  vi.stubGlobal('fetch', vi.fn(async (url, init) => {
    const op = init.headers['X-Amz-Target'].split('.').pop();
    const body = JSON.parse(init.body);
    calls.push({ op, body });
    const queue = routes[op];
    if (!queue || queue.length === 0) throw new Error(`unexpected Cognito call: ${op}`);
    return queue.shift();
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
});

async function renderSignedOut() {
  render(<App />);
  await screen.findByRole('button', { name: 'Sign in' });
}

async function signIn(password = 'correct horse battery') {
  fireEvent.change(screen.getByLabelText('Username'), { target: { name: 'userName', value: 'alice' } });
  fireEvent.change(screen.getByLabelText('Password'), { target: { name: 'password', value: password } });
  fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
}

function enterCode(label, code) {
  fireEvent.change(screen.getByLabelText(label), { target: { name: 'verificationCode', value: code } });
}

function localStorageText() {
  return Object.keys(window.localStorage).map((k) => `${k}=${window.localStorage.getItem(k)}`).join('\n');
}

describe('sign-in', () => {
  it('signs in with USER_PASSWORD_AUTH and keeps only the refresh token, in sessionStorage', async () => {
    cognito({ InitiateAuth: [auth()], GetUser: [user()] });
    await renderSignedOut();
    await signIn();

    expect((await screen.findByTestId('email-view')).textContent).toBe(PLAIN_ID);
    expect(sentTo('InitiateAuth')[0]).toEqual({
      AuthFlow: 'USER_PASSWORD_AUTH',
      ClientId: 'main-client',
      AuthParameters: { USERNAME: 'alice', PASSWORD: 'correct horse battery' },
    });
    expect(sentTo('GetUser')[0]).toEqual({ AccessToken: 'access-1' });
    expect(JSON.parse(window.sessionStorage.getItem(SESSION_STORAGE_KEY)))
      .toEqual({ username: 'alice', refreshToken: 'refresh-1' });
    const persisted = localStorageText();
    expect(persisted).not.toContain(PLAIN_ID);
    expect(persisted).not.toContain('refresh-1');
    expect(persisted).not.toContain('access-1');
    expect(persisted).not.toContain('correct horse battery');
    expect(screen.getByTestId('is-admin').textContent).toBe('false');
  });

  it('answers a TOTP challenge, echoing the session, and shows admin views to an admin', async () => {
    cognito({ InitiateAuth: [TOTP_CHALLENGE], RespondToAuthChallenge: [auth(ADMIN_ID)], GetUser: [user({ mfa: [] })] });
    await renderSignedOut();
    await signIn();

    await screen.findByText('Enter your code.');
    enterCode('Authentication code', '123456');
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));

    await screen.findByTestId('email-view');
    expect(sentTo('RespondToAuthChallenge')[0]).toEqual({
      ChallengeName: 'SOFTWARE_TOKEN_MFA',
      ClientId: 'main-client',
      Session: 'challenge-session',
      ChallengeResponses: { USERNAME: 'alice', SOFTWARE_TOKEN_MFA_CODE: '123456' },
    });
    // Just answered a TOTP challenge, so no enrollment nudge even though
    // GetUser listed no factor.
    expect(screen.getByTestId('is-admin').textContent).toBe('true');
  });

  it('keeps a wrong code on the challenge, and restarts an expired one', async () => {
    cognito({
      InitiateAuth: [TOTP_CHALLENGE],
      RespondToAuthChallenge: [
        cognitoError(400, 'CodeMismatchException', 'Invalid code received for user'),
        cognitoError(400, 'NotAuthorizedException', 'Invalid session for the user, session is expired.'),
      ],
    });
    await renderSignedOut();
    await signIn();
    await screen.findByText('Enter your code.');

    enterCode('Authentication code', '000000');
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
    await screen.findByText('That code did not match. Please try again.');
    expect(screen.getByText('Enter your code.')).toBeInTheDocument();

    enterCode('Authentication code', '111111');
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));
    await screen.findByText('Your sign-in session expired. Please log in again.');
    expect(screen.getByRole('button', { name: 'Sign in' })).toBeInTheDocument();
  });

  it('says so when the password is wrong', async () => {
    cognito({ InitiateAuth: [cognitoError(400, 'NotAuthorizedException', 'Incorrect username or password.')] });
    await renderSignedOut();
    await signIn('wrong');
    await screen.findByText('Login failed');
    expect(window.sessionStorage.getItem(SESSION_STORAGE_KEY)).toBeNull();
  });

  it('stops at the recovery-email gate when the address is unverified', async () => {
    cognito({ InitiateAuth: [auth()], GetUser: [user({ verified: false })], VerifyUserAttribute: [reply(200, {})] });
    await renderSignedOut();
    await signIn();

    await screen.findByLabelText('Verification code');
    enterCode('Verification code', '424242');
    fireEvent.click(screen.getByRole('button', { name: 'Verify' }));

    await screen.findByTestId('email-view');
    expect(sentTo('VerifyUserAttribute')[0]).toEqual({ AccessToken: 'access-1', AttributeName: 'email', Code: '424242' });
  });

  it('nudges an account with no second factor to enroll', async () => {
    cognito({ InitiateAuth: [auth()], GetUser: [user({ mfa: [] })] });
    await renderSignedOut();
    await signIn();
    await screen.findByText('Protect your account.');
  });

  it('lets a sign-in through when the GetUser read fails', async () => {
    cognito({ InitiateAuth: [auth()], GetUser: [cognitoError(500, 'InternalErrorException', 'boom')] });
    await renderSignedOut();
    await signIn();
    await screen.findByTestId('email-view');
  });
});

describe('locked-out TOTP setup', () => {
  it('routes the require_admin_mfa refusal to setup through the enrollment client, and persists none of it', async () => {
    cognito({
      InitiateAuth: [MFA_REFUSAL, auth(PLAIN_ID, { accessToken: 'enroll-access', refreshToken: 'enroll-refresh', expiresIn: 300 })],
      AssociateSoftwareToken: [reply(200, { SecretCode: 'JBSWY3DPEHPK3PXP' })],
      VerifySoftwareToken: [reply(200, { Status: 'SUCCESS' })],
      SetUserMFAPreference: [reply(200, {})],
    });
    await renderSignedOut();
    await signIn();

    fireEvent.click(await screen.findByRole('button', { name: 'Set up authenticator app' }));
    await screen.findByLabelText('Code from your app');
    expect(sentTo('InitiateAuth')[1].ClientId).toBe('enroll-client');
    expect(sentTo('AssociateSoftwareToken')[0]).toEqual({ AccessToken: 'enroll-access' });

    enterCode('Code from your app', '123456');
    fireEvent.click(screen.getByRole('button', { name: /turn on|verify|confirm/i }));

    await screen.findByText('Two-factor authentication is on. Sign in again with a code from your app.');
    expect(sentTo('VerifySoftwareToken')[0]).toEqual({
      AccessToken: 'enroll-access', UserCode: '123456', FriendlyDeviceName: 'Cabalmail',
    });
    expect(sentTo('SetUserMFAPreference')[0]).toEqual({
      AccessToken: 'enroll-access', SoftwareTokenMfaSettings: { Enabled: true, PreferredMfa: true },
    });
    expect(window.sessionStorage.getItem(SESSION_STORAGE_KEY)).toBeNull();
    expect(localStorageText()).not.toContain('enroll-access');
    expect(localStorageText()).not.toContain('enroll-refresh');
    expect(window.sessionStorage.length).toBe(0);
  });
});

describe('session lifetime', () => {
  it('restores a reload from sessionStorage without showing the sign-in form first', async () => {
    window.sessionStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ username: 'alice', refreshToken: 'refresh-1' }));
    window.localStorage.setItem('state', JSON.stringify({ loggedIn: true, view: 'Email', userName: 'alice' }));
    cognito({ InitiateAuth: [auth(ADMIN_ID, { refreshToken: null })] });
    render(<App />);
    expect(screen.queryByRole('button', { name: 'Sign in' })).toBeNull();

    expect((await screen.findByTestId('email-view')).textContent).toBe(ADMIN_ID);
    expect(sentTo('InitiateAuth')[0]).toEqual({
      AuthFlow: 'REFRESH_TOKEN_AUTH',
      ClientId: 'main-client',
      AuthParameters: { REFRESH_TOKEN: 'refresh-1' },
    });
    expect(screen.getByTestId('is-admin').textContent).toBe('true');
  });

  it('lands a reload on sign-in, and forgets the token, when Cognito refuses it', async () => {
    window.sessionStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify({ username: 'alice', refreshToken: 'stale' }));
    cognito({ InitiateAuth: [cognitoError(400, 'NotAuthorizedException', 'Refresh Token has expired')] });
    render(<App />);
    await screen.findByRole('button', { name: 'Sign in' });
    expect(window.sessionStorage.getItem(SESSION_STORAGE_KEY)).toBeNull();
  });

  it('starts a new tab signed out, whatever the shared state bag says', async () => {
    window.localStorage.setItem('state', JSON.stringify({ loggedIn: true, view: 'Email', userName: 'alice' }));
    await renderSignedOut();
    expect(screen.queryByTestId('email-view')).toBeNull();
    expect(calls).toHaveLength(0);
  });

  it('refreshes a token near expiry instead of signing out', async () => {
    // Sixty seconds left is inside the five-minute leeway, so the next
    // session check refreshes.
    const fresh = makeJwt({ 'cognito:username': 'alice', v: 2 });
    cognito({ InitiateAuth: [auth(PLAIN_ID, { expiresIn: 60 }), auth(fresh)], GetUser: [user()] });
    await renderSignedOut();
    await signIn();

    await waitFor(() => expect(screen.getByTestId('email-view').textContent).toBe(fresh));
    expect(sentTo('InitiateAuth')[1].AuthFlow).toBe('REFRESH_TOKEN_AUTH');
    expect(screen.queryByRole('button', { name: 'Sign in' })).toBeNull();
  });

  it('signs out to the form when Cognito refuses a refresh mid-session', async () => {
    cognito({
      InitiateAuth: [auth(PLAIN_ID, { expiresIn: 60 }), cognitoError(400, 'NotAuthorizedException', 'Refresh Token has been revoked')],
      GetUser: [user()],
    });
    await renderSignedOut();
    await signIn();
    await screen.findByRole('button', { name: 'Sign in' });
    expect(window.sessionStorage.getItem(SESSION_STORAGE_KEY)).toBeNull();
  });

  it('clears the session on sign-out', async () => {
    cognito({ InitiateAuth: [auth()], GetUser: [user()] });
    await renderSignedOut();
    await signIn();
    await screen.findByTestId('email-view');

    fireEvent.click(screen.getByRole('button', { name: 'Log out' }));
    await screen.findByRole('button', { name: 'Sign in' });
    expect(window.sessionStorage.getItem(SESSION_STORAGE_KEY)).toBeNull();
  });

  it("deletes the old library's tokens from localStorage on load, and nothing else", async () => {
    const prefix = 'CognitoIdentityServiceProvider.main-client';
    window.localStorage.setItem(`${prefix}.alice.idToken`, 'old-id');
    window.localStorage.setItem(`${prefix}.alice.refreshToken`, 'old-refresh');
    window.localStorage.setItem(`${prefix}.LastAuthUser`, 'alice');
    window.localStorage.setItem('theme', 'dark');
    await renderSignedOut();
    expect(Object.keys(window.localStorage).filter((k) => k.startsWith('CognitoIdentityServiceProvider.'))).toEqual([]);
    expect(window.localStorage.getItem('theme')).toBe('dark');
  });
});

describe('Security view', () => {
  it('reads TOTP status with GetUser and turns it off with SetUserMFAPreference', async () => {
    cognito({
      InitiateAuth: [auth()],
      GetUser: [user(), user()],
      SetUserMFAPreference: [reply(200, {})],
    });
    await renderSignedOut();
    await signIn();
    await screen.findByTestId('email-view');

    fireEvent.click(screen.getByRole('button', { name: 'Security' }));
    fireEvent.click(await screen.findByRole('button', { name: 'Turn off two-factor authentication' }));
    await screen.findByText('Two-factor authentication is off.');
    expect(sentTo('SetUserMFAPreference')[0]).toEqual({
      AccessToken: 'access-1', SoftwareTokenMfaSettings: { Enabled: false, PreferredMfa: false },
    });
  });
});

describe('sign-up', () => {
  async function fillSignUp(inviteCode) {
    await renderSignedOut();
    fireEvent.click(screen.getAllByText('Create an account')[0]);
    await screen.findByLabelText('Invitation code');
    const set = (label, name, value) => fireEvent.change(screen.getByLabelText(label), { target: { name, value } });
    set('Username', 'userName', 'newbie');
    set('Email address', 'email', 'newbie@example.com');
    set('Invitation code', 'inviteCode', inviteCode);
    set('Password', 'password', 'Long-enough-pw1');
    fireEvent.change(screen.getByLabelText('Confirm password'), { target: { value: 'Long-enough-pw1' } });
    fireEvent.click(screen.getByRole('button', { name: /create account/i }));
  }

  it('shows the invitation-code refusal', async () => {
    cognito({ SignUp: [cognitoError(400, 'UserLambdaValidationException', 'PreSignUp failed with error Invalid invitation code..')] });
    await fillSignUp('wrong');
    await screen.findByText('Invalid invitation code.');
    expect(sentTo('SignUp')[0].ValidationData).toEqual([{ Name: 'invitationCode', Value: 'wrong' }]);
    expect(sentTo('SignUp')[0].UserAttributes).toEqual([
      { Name: 'preferred_username', Value: 'newbie' },
      { Name: 'email', Value: 'newbie@example.com' },
    ]);
  });

  it('reports an auto-confirmed account as pending approval', async () => {
    cognito({ SignUp: [reply(200, { UserConfirmed: true, UserSub: 's' })] });
    await fillSignUp('right');
    await screen.findByText("Account created. It is pending admin approval; you'll be notified when it is ready.");
  });

  it('goes to code entry when Cognito sends a confirmation code', async () => {
    cognito({
      SignUp: [reply(200, { UserConfirmed: false, CodeDeliveryDetails: { DeliveryMedium: 'EMAIL', Destination: 'n***@e***' } })],
      ConfirmSignUp: [reply(200, {})],
    });
    await fillSignUp('right');
    await screen.findByText('Check your email for a verification code.');
    enterCode('Verification code', '777777');
    fireEvent.click(screen.getByRole('button', { name: /verify/i }));
    await screen.findByText('Email verified. Your account is pending admin approval.');
    expect(sentTo('ConfirmSignUp')[0]).toEqual({ ClientId: 'main-client', Username: 'newbie', ConfirmationCode: '777777' });
  });
});

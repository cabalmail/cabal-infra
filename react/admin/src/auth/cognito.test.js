import { describe, it, expect } from 'vitest';
import { createCognitoClient, clientsFromConfig } from './cognito';
import {
  CognitoError,
  isInvalidInvitationCode,
  isMfaEnrollmentRequired,
  isCodeMismatch,
  isNotAuthorized,
  isLimitExceeded,
} from './errors';
import { signUpErrorMessage } from '../SignUp/signUpError';
import { stubFetch, reply, cognitoError, sent } from '../test/cognito';

const NOW = 1_800_000_000_000;

function client(fetchImpl, clientId = 'main-client') {
  return createCognitoClient({ region: 'us-east-1', clientId, fetchImpl, now: () => NOW });
}

const AUTH_RESULT = {
  AuthenticationResult: {
    IdToken: 'id-1',
    AccessToken: 'access-1',
    RefreshToken: 'refresh-1',
    ExpiresIn: 43200,
    TokenType: 'Bearer',
  },
};

// The messages Cognito sends when a pool trigger refuses: it wraps the
// trigger's own text in "<Trigger> failed with error <text>." The
// trigger texts are lambda/counter/check_invite and require_admin_mfa's.
const INVALID_INVITE = cognitoError(400, 'UserLambdaValidationException',
  'PreSignUp failed with error Invalid invitation code..');
const RESERVED_USERNAME = cognitoError(400, 'UserLambdaValidationException',
  'PreSignUp failed with error That username is reserved. Choose another..');
const MFA_REFUSAL = cognitoError(400, 'UserLambdaValidationException',
  'PreTokenGeneration failed with error This account requires multi-factor authentication. '
  + 'Sign in on the web app to set up an authenticator, then try again.');
const WRONG_PASSWORD = cognitoError(400, 'NotAuthorizedException', 'Incorrect username or password.');
const WRONG_CODE = cognitoError(400, 'CodeMismatchException', 'Invalid code received for user');

describe('transport', () => {
  it('POSTs JSON to the regional endpoint with the operation in X-Amz-Target', async () => {
    const fetchImpl = stubFetch(reply(200, {}));
    await client(fetchImpl).confirmSignUp('alice', '123456');
    const req = sent(fetchImpl);
    expect(req.url).toBe('https://cognito-idp.us-east-1.amazonaws.com/');
    expect(req.method).toBe('POST');
    expect(req.contentType).toBe('application/x-amz-json-1.1');
    expect(req.target).toBe('AWSCognitoIdentityProviderService.ConfirmSignUp');
  });

  it('maps a namespaced __type to the bare exception name, in code and name', async () => {
    const fetchImpl = stubFetch(reply(400, {
      __type: 'com.amazonaws.cognito.identity.idp.model#UserNotFoundException',
      message: 'User does not exist.',
    }));
    const err = await client(fetchImpl).forgotPassword('nobody').catch((e) => e);
    expect(err).toBeInstanceOf(CognitoError);
    expect(err.code).toBe('UserNotFoundException');
    expect(err.name).toBe('UserNotFoundException');
    expect(err.message).toBe('User does not exist.');
    expect(err.status).toBe(400);
  });

  it('reports a fetch that never reached Cognito as NetworkError', async () => {
    const fetchImpl = stubFetch(new TypeError('Failed to fetch'));
    const err = await client(fetchImpl).signIn('alice', 'pw').catch((e) => e);
    expect(err.code).toBe('NetworkError');
    expect(err.cause).toBeInstanceOf(TypeError);
  });

  it('refuses a 2xx whose body is not JSON (a captive portal page)', async () => {
    const fetchImpl = stubFetch(reply(200, '<html>Sign in to the Wi-Fi</html>'));
    const err = await client(fetchImpl).signIn('alice', 'pw').catch((e) => e);
    expect(err.code).toBe('UnreadableResponse');
  });

  it('keeps an error status whose body is not JSON', async () => {
    const fetchImpl = stubFetch(reply(503, 'Service Unavailable'));
    const err = await client(fetchImpl).signIn('alice', 'pw').catch((e) => e);
    expect(err.code).toBe('UnknownError');
    expect(err.status).toBe(503);
  });

  it('needs a region and a client ID', () => {
    expect(() => createCognitoClient({ region: 'us-east-1' })).toThrow();
    expect(() => createCognitoClient({ clientId: 'x' })).toThrow();
  });
});

describe('signUp', () => {
  it('sends the contract body: preferred_username, email, phone, and the code as ValidationData', async () => {
    const fetchImpl = stubFetch(reply(200, {
      UserConfirmed: false,
      UserSub: 'sub-1',
      CodeDeliveryDetails: { DeliveryMedium: 'SMS', Destination: '+*******1234', AttributeName: 'phone_number' },
    }));
    const result = await client(fetchImpl).signUp({
      username: 'alice',
      password: 'pw',
      email: 'alice@example.com',
      phone: '+15555551234',
      invitationCode: 'let-me-in',
    });
    const req = sent(fetchImpl);
    expect(req.target).toBe('AWSCognitoIdentityProviderService.SignUp');
    expect(req.body).toEqual({
      ClientId: 'main-client',
      Username: 'alice',
      Password: 'pw',
      UserAttributes: [
        { Name: 'preferred_username', Value: 'alice' },
        { Name: 'email', Value: 'alice@example.com' },
        { Name: 'phone_number', Value: '+15555551234' },
      ],
      ValidationData: [{ Name: 'invitationCode', Value: 'let-me-in' }],
    });
    expect(result).toEqual({
      userConfirmed: false,
      userSub: 'sub-1',
      codeDelivery: { medium: 'phone', destination: '+*******1234' },
    });
  });

  it('omits the phone without one and still sends an empty invitation code', async () => {
    const fetchImpl = stubFetch(reply(200, { UserConfirmed: true, UserSub: 'sub-2' }));
    await client(fetchImpl).signUp({ username: 'bob', password: 'pw', email: 'bob@example.com' });
    const { body } = sent(fetchImpl);
    expect(body.UserAttributes.map((a) => a.Name)).toEqual(['preferred_username', 'email']);
    expect(body.ValidationData).toEqual([{ Name: 'invitationCode', Value: '' }]);
  });

  it('reports no code delivery when check_invite auto-confirmed the account', async () => {
    const fetchImpl = stubFetch(reply(200, { UserConfirmed: true, UserSub: 'sub-2' }));
    const result = await client(fetchImpl).signUp({ username: 'bob', password: 'pw', email: 'b@example.com' });
    expect(result.codeDelivery).toBeNull();
    expect(result.userConfirmed).toBe(true);
  });

  it('reports an email delivery as email', async () => {
    const fetchImpl = stubFetch(reply(200, {
      UserConfirmed: false,
      CodeDeliveryDetails: { DeliveryMedium: 'EMAIL', Destination: 'a***@e***.com' },
    }));
    const result = await client(fetchImpl).signUp({ username: 'a', password: 'pw', email: 'a@example.com' });
    expect(result.codeDelivery).toEqual({ medium: 'email', destination: 'a***@e***.com' });
  });

  it('maps a wrong invitation code, and the sign-up screen still words it', async () => {
    const fetchImpl = stubFetch(INVALID_INVITE);
    const err = await client(fetchImpl).signUp({ username: 'a', password: 'pw', email: 'a@example.com' })
      .catch((e) => e);
    expect(isInvalidInvitationCode(err)).toBe(true);
    expect(signUpErrorMessage(err)).toBe('Invalid invitation code.');
  });

  it("doesn't call a username refusal an invitation-code one", async () => {
    const fetchImpl = stubFetch(RESERVED_USERNAME);
    const err = await client(fetchImpl).signUp({ username: 'root', password: 'pw', email: 'a@example.com' })
      .catch((e) => e);
    expect(isInvalidInvitationCode(err)).toBe(false);
    expect(signUpErrorMessage(err)).toBe('That username is reserved. Choose another.');
  });
});

describe('confirmation codes', () => {
  it('confirms a sign-up', async () => {
    const fetchImpl = stubFetch(reply(200, {}));
    await client(fetchImpl).confirmSignUp('alice', '123456');
    expect(sent(fetchImpl).body).toEqual({ ClientId: 'main-client', Username: 'alice', ConfirmationCode: '123456' });
  });

  it('maps a wrong confirmation code', async () => {
    const fetchImpl = stubFetch(WRONG_CODE);
    const err = await client(fetchImpl).confirmSignUp('alice', '000000').catch((e) => e);
    expect(isCodeMismatch(err)).toBe(true);
  });

  it('resends a confirmation code and says where it went', async () => {
    const fetchImpl = stubFetch(reply(200, { CodeDeliveryDetails: { DeliveryMedium: 'EMAIL', Destination: 'a***' } }));
    const delivery = await client(fetchImpl).resendConfirmationCode('alice');
    expect(sent(fetchImpl).target).toBe('AWSCognitoIdentityProviderService.ResendConfirmationCode');
    expect(sent(fetchImpl).body).toEqual({ ClientId: 'main-client', Username: 'alice' });
    expect(delivery).toEqual({ medium: 'email', destination: 'a***' });
  });

  it('maps the resend limit', async () => {
    const fetchImpl = stubFetch(cognitoError(400, 'LimitExceededException', 'Attempt limit exceeded, please try after some time.'));
    const err = await client(fetchImpl).resendConfirmationCode('alice').catch((e) => e);
    expect(isLimitExceeded(err)).toBe(true);
    // The library-era check in App.jsx keeps working too.
    expect(err.code === 'LimitExceededException' || err.name === 'LimitExceededException').toBe(true);
  });
});

describe('signIn', () => {
  it('signs in with USER_PASSWORD_AUTH (D1), not SRP', async () => {
    const fetchImpl = stubFetch(reply(200, AUTH_RESULT));
    const result = await client(fetchImpl).signIn('alice', 'pw');
    const req = sent(fetchImpl);
    expect(req.target).toBe('AWSCognitoIdentityProviderService.InitiateAuth');
    expect(req.body).toEqual({
      AuthFlow: 'USER_PASSWORD_AUTH',
      ClientId: 'main-client',
      AuthParameters: { USERNAME: 'alice', PASSWORD: 'pw' },
    });
    expect(result).toEqual({
      status: 'signed-in',
      tokens: { idToken: 'id-1', accessToken: 'access-1', refreshToken: 'refresh-1', expiresAt: NOW + 43200 * 1000 },
    });
  });

  it('returns a TOTP challenge with what RespondToAuthChallenge needs', async () => {
    const fetchImpl = stubFetch(reply(200, {
      ChallengeName: 'SOFTWARE_TOKEN_MFA',
      Session: 'session-1',
      ChallengeParameters: { USER_ID_FOR_SRP: 'alice' },
    }));
    const result = await client(fetchImpl).signIn('Alice', 'pw');
    expect(result).toEqual({
      status: 'mfa',
      mfa: 'totp',
      challenge: { name: 'SOFTWARE_TOKEN_MFA', session: 'session-1', username: 'alice', destination: null },
    });
  });

  it('returns an SMS challenge with its destination', async () => {
    const fetchImpl = stubFetch(reply(200, {
      ChallengeName: 'SMS_MFA',
      Session: 'session-2',
      ChallengeParameters: { CODE_DELIVERY_DESTINATION: '+*******1234', CODE_DELIVERY_DELIVERY_MEDIUM: 'SMS' },
    }));
    const result = await client(fetchImpl).signIn('alice', 'pw');
    expect(result.mfa).toBe('sms');
    expect(result.challenge.username).toBe('alice');
    expect(result.challenge.destination).toBe('+*******1234');
  });

  it('refuses a challenge the webmail has no screen for', async () => {
    const fetchImpl = stubFetch(reply(200, { ChallengeName: 'NEW_PASSWORD_REQUIRED', Session: 's' }));
    const err = await client(fetchImpl).signIn('alice', 'pw').catch((e) => e);
    expect(err.code).toBe('UnsupportedChallenge');
  });

  it('maps a wrong password to NotAuthorized, and not to the MFA refusal', async () => {
    const fetchImpl = stubFetch(WRONG_PASSWORD);
    const err = await client(fetchImpl).signIn('alice', 'nope').catch((e) => e);
    expect(isNotAuthorized(err)).toBe(true);
    expect(isMfaEnrollmentRequired(err)).toBe(false);
  });

  it("recognizes require_admin_mfa's refusal of an account with no second factor", async () => {
    const fetchImpl = stubFetch(MFA_REFUSAL);
    const err = await client(fetchImpl).signIn('alice', 'pw').catch((e) => e);
    expect(isMfaEnrollmentRequired(err)).toBe(true);
    expect(isNotAuthorized(err)).toBe(false);
    expect(isInvalidInvitationCode(err)).toBe(false);
  });

  it('signs in through the enrollment client with its own client ID', async () => {
    const fetchImpl = stubFetch(reply(200, AUTH_RESULT));
    await client(fetchImpl, 'enroll-client').signIn('alice', 'pw');
    expect(sent(fetchImpl).body.ClientId).toBe('enroll-client');
  });
});

describe('respondToMfaChallenge', () => {
  const challenge = { name: 'SOFTWARE_TOKEN_MFA', session: 'session-1', username: 'alice', destination: null };

  it('answers a TOTP challenge, echoing Session and USERNAME', async () => {
    const fetchImpl = stubFetch(reply(200, AUTH_RESULT));
    const result = await client(fetchImpl).respondToMfaChallenge(challenge, '123456');
    const req = sent(fetchImpl);
    expect(req.target).toBe('AWSCognitoIdentityProviderService.RespondToAuthChallenge');
    expect(req.body).toEqual({
      ChallengeName: 'SOFTWARE_TOKEN_MFA',
      ClientId: 'main-client',
      Session: 'session-1',
      ChallengeResponses: { USERNAME: 'alice', SOFTWARE_TOKEN_MFA_CODE: '123456' },
    });
    expect(result.status).toBe('signed-in');
    expect(result.tokens.idToken).toBe('id-1');
  });

  it('answers an SMS challenge with SMS_MFA_CODE', async () => {
    const fetchImpl = stubFetch(reply(200, AUTH_RESULT));
    await client(fetchImpl).respondToMfaChallenge({ ...challenge, name: 'SMS_MFA' }, '654321');
    expect(sent(fetchImpl).body.ChallengeResponses).toEqual({ USERNAME: 'alice', SMS_MFA_CODE: '654321' });
  });

  it('maps a wrong second-factor code', async () => {
    const fetchImpl = stubFetch(WRONG_CODE);
    const err = await client(fetchImpl).respondToMfaChallenge(challenge, '000000').catch((e) => e);
    expect(isCodeMismatch(err)).toBe(true);
    expect(isNotAuthorized(err)).toBe(false);
  });

  it('maps an expired challenge session to NotAuthorized', async () => {
    const fetchImpl = stubFetch(cognitoError(400, 'NotAuthorizedException', 'Invalid session for the user, session is expired.'));
    const err = await client(fetchImpl).respondToMfaChallenge(challenge, '123456').catch((e) => e);
    expect(isNotAuthorized(err)).toBe(true);
    expect(isCodeMismatch(err)).toBe(false);
  });

  it('recognizes the MFA refusal after the challenge too', async () => {
    const fetchImpl = stubFetch(MFA_REFUSAL);
    const err = await client(fetchImpl).respondToMfaChallenge(challenge, '123456').catch((e) => e);
    expect(isMfaEnrollmentRequired(err)).toBe(true);
  });
});

describe('refresh', () => {
  it('uses REFRESH_TOKEN_AUTH and keeps the refresh token Cognito leaves out', async () => {
    const fetchImpl = stubFetch(reply(200, {
      AuthenticationResult: { IdToken: 'id-2', AccessToken: 'access-2', ExpiresIn: 3600 },
    }));
    const tokens = await client(fetchImpl).refresh('refresh-1');
    expect(sent(fetchImpl).body).toEqual({
      AuthFlow: 'REFRESH_TOKEN_AUTH',
      ClientId: 'main-client',
      AuthParameters: { REFRESH_TOKEN: 'refresh-1' },
    });
    expect(tokens).toEqual({ idToken: 'id-2', accessToken: 'access-2', refreshToken: 'refresh-1', expiresAt: NOW + 3600 * 1000 });
  });

  it('takes a rotated refresh token', async () => {
    const fetchImpl = stubFetch(reply(200, {
      AuthenticationResult: { IdToken: 'id-2', AccessToken: 'access-2', RefreshToken: 'refresh-2', ExpiresIn: 3600 },
    }));
    expect((await client(fetchImpl).refresh('refresh-1')).refreshToken).toBe('refresh-2');
  });

  it('refuses a reply with no tokens', async () => {
    const fetchImpl = stubFetch(reply(200, {}));
    const err = await client(fetchImpl).refresh('refresh-1').catch((e) => e);
    expect(err.code).toBe('UnreadableResponse');
  });
});

describe('password reset', () => {
  it('starts a reset and reports where the code went', async () => {
    const fetchImpl = stubFetch(reply(200, { CodeDeliveryDetails: { DeliveryMedium: 'EMAIL', Destination: 'a***' } }));
    const delivery = await client(fetchImpl).forgotPassword('alice');
    expect(sent(fetchImpl).target).toBe('AWSCognitoIdentityProviderService.ForgotPassword');
    expect(sent(fetchImpl).body).toEqual({ ClientId: 'main-client', Username: 'alice' });
    expect(delivery).toEqual({ medium: 'email', destination: 'a***' });
  });

  it('confirms the reset with the code and the new password', async () => {
    const fetchImpl = stubFetch(reply(200, {}));
    await client(fetchImpl).confirmForgotPassword('alice', '123456', 'new-pw');
    expect(sent(fetchImpl).target).toBe('AWSCognitoIdentityProviderService.ConfirmForgotPassword');
    expect(sent(fetchImpl).body).toEqual({
      ClientId: 'main-client', Username: 'alice', ConfirmationCode: '123456', Password: 'new-pw',
    });
  });
});

describe('signed-in user operations', () => {
  it('reads attributes and MFA state in one GetUser', async () => {
    const fetchImpl = stubFetch(reply(200, {
      Username: 'alice',
      UserAttributes: [
        { Name: 'email', Value: 'alice@example.com' },
        { Name: 'email_verified', Value: 'false' },
      ],
      UserMFASettingList: ['SOFTWARE_TOKEN_MFA'],
      PreferredMfaSetting: 'SOFTWARE_TOKEN_MFA',
    }));
    const user = await client(fetchImpl).getUser('access-1');
    expect(sent(fetchImpl).body).toEqual({ AccessToken: 'access-1' });
    expect(user).toEqual({
      username: 'alice',
      attributes: { email: 'alice@example.com', email_verified: 'false' },
      mfaSettings: ['SOFTWARE_TOKEN_MFA'],
      preferredMfa: 'SOFTWARE_TOKEN_MFA',
    });
  });

  it('reads a user with no MFA as an empty list', async () => {
    const fetchImpl = stubFetch(reply(200, { Username: 'bob', UserAttributes: [] }));
    expect((await client(fetchImpl).getUser('t')).mfaSettings).toEqual([]);
  });

  it('updates attributes from a name-to-value map', async () => {
    const fetchImpl = stubFetch(reply(200, {
      CodeDeliveryDetailsList: [{ DeliveryMedium: 'EMAIL', Destination: 'n***', AttributeName: 'email' }],
    }));
    const deliveries = await client(fetchImpl).updateUserAttributes('access-1', { email: 'new@example.com' });
    expect(sent(fetchImpl).body).toEqual({
      AccessToken: 'access-1',
      UserAttributes: [{ Name: 'email', Value: 'new@example.com' }],
    });
    expect(deliveries).toEqual([{ medium: 'email', destination: 'n***' }]);
  });

  it('asks for an attribute verification code', async () => {
    const fetchImpl = stubFetch(reply(200, { CodeDeliveryDetails: { DeliveryMedium: 'EMAIL', Destination: 'a***' } }));
    await client(fetchImpl).getUserAttributeVerificationCode('access-1', 'email');
    expect(sent(fetchImpl).target).toBe('AWSCognitoIdentityProviderService.GetUserAttributeVerificationCode');
    expect(sent(fetchImpl).body).toEqual({ AccessToken: 'access-1', AttributeName: 'email' });
  });

  it('verifies an attribute', async () => {
    const fetchImpl = stubFetch(reply(200, {}));
    await client(fetchImpl).verifyUserAttribute('access-1', 'email', '123456');
    expect(sent(fetchImpl).target).toBe('AWSCognitoIdentityProviderService.VerifyUserAttribute');
    expect(sent(fetchImpl).body).toEqual({ AccessToken: 'access-1', AttributeName: 'email', Code: '123456' });
  });

  it('maps the verification-code limit', async () => {
    const fetchImpl = stubFetch(cognitoError(400, 'LimitExceededException', 'Attempt limit exceeded'));
    const err = await client(fetchImpl).getUserAttributeVerificationCode('t', 'email').catch((e) => e);
    expect(isLimitExceeded(err)).toBe(true);
  });
});

describe('TOTP setup', () => {
  it('associates a software token and returns the secret', async () => {
    const fetchImpl = stubFetch(reply(200, { SecretCode: 'JBSWY3DPEHPK3PXP' }));
    expect(await client(fetchImpl).associateSoftwareToken('access-1')).toBe('JBSWY3DPEHPK3PXP');
    expect(sent(fetchImpl).body).toEqual({ AccessToken: 'access-1' });
  });

  it('verifies the first code under the Cabalmail device name', async () => {
    const fetchImpl = stubFetch(reply(200, { Status: 'SUCCESS' }));
    await client(fetchImpl).verifySoftwareToken('access-1', '123456');
    expect(sent(fetchImpl).body).toEqual({ AccessToken: 'access-1', UserCode: '123456', FriendlyDeviceName: 'Cabalmail' });
  });

  it('treats a non-SUCCESS verification as a wrong code', async () => {
    const fetchImpl = stubFetch(reply(200, { Status: 'ERROR' }));
    const err = await client(fetchImpl).verifySoftwareToken('access-1', '123456').catch((e) => e);
    expect(isCodeMismatch(err)).toBe(true);
  });

  it("maps Cognito's wrong-first-code error", async () => {
    const fetchImpl = stubFetch(cognitoError(400, 'EnableSoftwareTokenMFAException', 'Code mismatch'));
    const err = await client(fetchImpl).verifySoftwareToken('access-1', '000000').catch((e) => e);
    expect(isCodeMismatch(err)).toBe(true);
  });

  it('turns TOTP on as enabled and preferred, and off as neither', async () => {
    const fetchImpl = stubFetch(reply(200, {}), reply(200, {}));
    const c = client(fetchImpl);
    await c.setSoftwareTokenMfa('access-1', true);
    await c.setSoftwareTokenMfa('access-1', false);
    expect(sent(fetchImpl, 0).target).toBe('AWSCognitoIdentityProviderService.SetUserMFAPreference');
    expect(sent(fetchImpl, 0).body).toEqual({
      AccessToken: 'access-1', SoftwareTokenMfaSettings: { Enabled: true, PreferredMfa: true },
    });
    expect(sent(fetchImpl, 1).body.SoftwareTokenMfaSettings).toEqual({ Enabled: false, PreferredMfa: false });
  });
});

describe('clientsFromConfig', () => {
  const cognitoConfig = {
    region: 'us-west-2',
    poolData: { UserPoolId: 'us-west-2_abc', ClientId: 'main-client' },
    enrollClientId: 'enroll-client',
  };

  it('builds the main and enrollment clients from /config.js', async () => {
    const fetchImpl = stubFetch(reply(200, AUTH_RESULT), reply(200, AUTH_RESULT));
    const { client: main, enrollClient } = clientsFromConfig(cognitoConfig, { fetchImpl });
    await main.signIn('a', 'pw');
    await enrollClient.signIn('a', 'pw');
    expect(sent(fetchImpl, 0).url).toBe('https://cognito-idp.us-west-2.amazonaws.com/');
    expect(sent(fetchImpl, 0).body.ClientId).toBe('main-client');
    expect(sent(fetchImpl, 1).body.ClientId).toBe('enroll-client');
  });

  it('has no enrollment client for a /config.js without one', () => {
    const { enrollClient } = clientsFromConfig({ ...cognitoConfig, enrollClientId: '' });
    expect(enrollClient).toBeNull();
  });

  it("falls back to the pool ID's region", async () => {
    const fetchImpl = stubFetch(reply(200, AUTH_RESULT));
    const { client: main } = clientsFromConfig({ ...cognitoConfig, region: undefined }, { fetchImpl });
    await main.signIn('a', 'pw');
    expect(sent(fetchImpl).url).toBe('https://cognito-idp.us-west-2.amazonaws.com/');
  });
});

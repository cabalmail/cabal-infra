/**
 * Cognito user-pool client over the JSON API, the way the Apple and Android
 * kits talk to it (the contract is docs/auth.md).
 *
 * Every operation is one POST to https://cognito-idp.<region>.amazonaws.com/
 * with an X-Amz-Target header naming it. Nothing here is signed: these are
 * the operations Cognito accepts from a public app client, authenticated by
 * the request body (a password, a code, a refresh or access token).
 *
 * Sign-in is USER_PASSWORD_AUTH (decision D1), not the SRP flow
 * amazon-cognito-identity-js used. No state lives here; the session holder
 * (session.js) owns the tokens.
 */

import { CognitoError, errorFromResponse } from './errors';

const TARGET_PREFIX = 'AWSCognitoIdentityProviderService.';

const MFA_CHALLENGES = {
  SOFTWARE_TOKEN_MFA: { mfa: 'totp', codeKey: 'SOFTWARE_TOKEN_MFA_CODE' },
  SMS_MFA: { mfa: 'sms', codeKey: 'SMS_MFA_CODE' },
};

/**
 * @typedef {object} Tokens
 * @property {string} idToken - sent on API calls.
 * @property {string} accessToken - authorizes the self-service user
 *   operations (GetUser, attribute verification, TOTP setup).
 * @property {string|null} refreshToken - null only if Cognito omitted it.
 * @property {number} expiresAt - when the ID and access tokens expire, in
 *   epoch milliseconds by the local clock.
 */

/**
 * @typedef {object} CodeDelivery
 * @property {'email'|'phone'} medium - where Cognito sent the code.
 * @property {string|null} destination - Cognito's masked rendering of the
 *   address or number.
 */

/**
 * @typedef {object} MfaChallenge
 * @property {string} name - SOFTWARE_TOKEN_MFA or SMS_MFA.
 * @property {string} session - opaque; RespondToAuthChallenge echoes it.
 * @property {string} username - the USERNAME to answer with.
 * @property {string|null} destination - where an SMS code went.
 */

/**
 * @typedef {{status: 'signed-in', tokens: Tokens}
 *   | {status: 'mfa', mfa: 'totp'|'sms', challenge: MfaChallenge}} SignInResult
 */

/**
 * Normalize Cognito's CodeDeliveryDetails.
 *
 * @param {object|undefined} details
 * @returns {CodeDelivery|null} null when Cognito sent no code.
 */
export function codeDelivery(details) {
  if (!details) return null;
  return {
    medium: details.DeliveryMedium === 'EMAIL' ? 'email' : 'phone',
    destination: details.Destination || null,
  };
}

/**
 * Create a client for one app client of the pool. The webmail makes two:
 * the main client, and the enrollment client (`enrollClientId`) the
 * locked-out TOTP setup signs in through.
 *
 * @param {object} options
 * @param {string} options.region - e.g. us-east-1.
 * @param {string} options.clientId - the app client to sign in through.
 * @param {typeof fetch} [options.fetchImpl] - defaults to the global fetch.
 * @param {() => number} [options.now] - epoch ms; defaults to Date.now.
 */
export function createCognitoClient({ region, clientId, fetchImpl, now = Date.now }) {
  if (!region || !clientId) {
    throw new Error('createCognitoClient needs a region and a clientId');
  }
  const endpoint = `https://cognito-idp.${region}.amazonaws.com/`;
  const doFetch = fetchImpl || ((...args) => globalThis.fetch(...args));

  async function call(operation, body) {
    let response;
    try {
      response = await doFetch(endpoint, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-amz-json-1.1',
          'X-Amz-Target': TARGET_PREFIX + operation,
        },
        body: JSON.stringify(body),
        cache: 'no-store',
      });
    } catch (cause) {
      throw new CognitoError('NetworkError', 'Could not reach the sign-in service.', { cause });
    }
    let text = '';
    try {
      text = await response.text();
    } catch {
      text = '';
    }
    let data = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = null;
      }
    }
    if (!response.ok) throw errorFromResponse(response.status, data);
    if (text && (data === null || typeof data !== 'object')) {
      // A 2xx that isn't JSON (a captive portal, a proxy page) is not a
      // Cognito answer; say so rather than letting a parse error escape.
      throw new CognitoError(
        'UnreadableResponse',
        'The sign-in service sent a reply that could not be read.',
        { status: response.status },
      );
    }
    return data || {};
  }

  function tokensFrom(result, fallbackRefreshToken = null) {
    if (!result || !result.IdToken || !result.AccessToken) {
      throw new CognitoError('UnreadableResponse', 'Cognito returned no tokens.');
    }
    const expiresIn = Number(result.ExpiresIn) > 0 ? Number(result.ExpiresIn) : 3600;
    return {
      idToken: result.IdToken,
      accessToken: result.AccessToken,
      refreshToken: result.RefreshToken || fallbackRefreshToken,
      expiresAt: now() + expiresIn * 1000,
    };
  }

  function signInResult(data, username) {
    if (data.AuthenticationResult) {
      return { status: 'signed-in', tokens: tokensFrom(data.AuthenticationResult) };
    }
    const known = MFA_CHALLENGES[data.ChallengeName];
    if (!known || !data.Session) {
      // NEW_PASSWORD_REQUIRED, MFA_SETUP, SELECT_MFA_TYPE: nothing the
      // pool's configuration produces for a self-service user.
      throw new CognitoError(
        'UnsupportedChallenge',
        `Cognito asked for an unsupported sign-in step (${data.ChallengeName || 'none'}).`,
      );
    }
    const params = data.ChallengeParameters || {};
    return {
      status: 'mfa',
      mfa: known.mfa,
      challenge: {
        name: data.ChallengeName,
        session: data.Session,
        // Cognito names the user it resolved the sign-in to; answer
        // with that rather than what was typed.
        username: params.USER_ID_FOR_SRP || username,
        destination: params.CODE_DELIVERY_DESTINATION || null,
      },
    };
  }

  return {
    clientId,

    /**
     * Create an account. The invitation code goes in ValidationData so the
     * check_invite trigger can read it without it landing on the user
     * record; it is sent (empty) even when the pool needs none.
     *
     * @param {object} params
     * @param {string} params.username
     * @param {string} params.password
     * @param {string} [params.email] - the recovery email.
     * @param {string} [params.phone] - E.164; pass it only when the pool
     *   has SMS (`sms_enabled` in /config.js).
     * @param {string} [params.invitationCode]
     * @returns {Promise<{userConfirmed: boolean, userSub: string|null,
     *   codeDelivery: CodeDelivery|null}>} codeDelivery is null when no
     *   code was sent: check_invite auto-confirmed the account (SMS off),
     *   and it is now pending admin approval.
     */
    async signUp({ username, password, email, phone, invitationCode }) {
      const attributes = [{ Name: 'preferred_username', Value: username }];
      if (email) attributes.push({ Name: 'email', Value: email });
      if (phone) attributes.push({ Name: 'phone_number', Value: phone });
      const data = await call('SignUp', {
        ClientId: clientId,
        Username: username,
        Password: password,
        UserAttributes: attributes,
        ValidationData: [{ Name: 'invitationCode', Value: invitationCode || '' }],
      });
      return {
        userConfirmed: data.UserConfirmed === true,
        userSub: data.UserSub || null,
        codeDelivery: codeDelivery(data.CodeDeliveryDetails),
      };
    },

    /** @returns {Promise<void>} */
    async confirmSignUp(username, code) {
      await call('ConfirmSignUp', {
        ClientId: clientId,
        Username: username,
        ConfirmationCode: code,
      });
    },

    /** @returns {Promise<CodeDelivery|null>} */
    async resendConfirmationCode(username) {
      const data = await call('ResendConfirmationCode', {
        ClientId: clientId,
        Username: username,
      });
      return codeDelivery(data.CodeDeliveryDetails);
    },

    /** @returns {Promise<SignInResult>} */
    async signIn(username, password) {
      const data = await call('InitiateAuth', {
        AuthFlow: 'USER_PASSWORD_AUTH',
        ClientId: clientId,
        AuthParameters: { USERNAME: username, PASSWORD: password },
      });
      return signInResult(data, username);
    },

    /**
     * Answer a second-factor challenge from signIn. A wrong code throws
     * CodeMismatchException and the challenge stays answerable for a few
     * more tries; an expired one throws NotAuthorizedException.
     *
     * @param {MfaChallenge} challenge
     * @param {string} code
     * @returns {Promise<SignInResult>}
     */
    async respondToMfaChallenge(challenge, code) {
      const known = MFA_CHALLENGES[challenge.name];
      if (!known) {
        throw new CognitoError('UnsupportedChallenge', `Not an MFA challenge: ${challenge.name}`);
      }
      const data = await call('RespondToAuthChallenge', {
        ChallengeName: challenge.name,
        ClientId: clientId,
        Session: challenge.session,
        ChallengeResponses: { USERNAME: challenge.username, [known.codeKey]: code },
      });
      return signInResult(data, challenge.username);
    },

    /**
     * Trade a refresh token for new ID and access tokens. Cognito leaves
     * the refresh token out of the reply unless it rotated it, so the one
     * passed in is kept.
     *
     * @param {string} refreshToken
     * @returns {Promise<Tokens>}
     */
    async refresh(refreshToken) {
      const data = await call('InitiateAuth', {
        AuthFlow: 'REFRESH_TOKEN_AUTH',
        ClientId: clientId,
        AuthParameters: { REFRESH_TOKEN: refreshToken },
      });
      if (!data.AuthenticationResult) {
        throw new CognitoError('UnreadableResponse', 'Cognito returned no tokens.');
      }
      return tokensFrom(data.AuthenticationResult, refreshToken);
    },

    /** @returns {Promise<CodeDelivery|null>} */
    async forgotPassword(username) {
      const data = await call('ForgotPassword', {
        ClientId: clientId,
        Username: username,
      });
      return codeDelivery(data.CodeDeliveryDetails);
    },

    /** @returns {Promise<void>} */
    async confirmForgotPassword(username, code, password) {
      await call('ConfirmForgotPassword', {
        ClientId: clientId,
        Username: username,
        ConfirmationCode: code,
        Password: password,
      });
    },

    /**
     * The signed-in user's attributes and MFA state, in one call (the
     * library split it into getUserAttributes and getUserData).
     *
     * @param {string} accessToken
     * @returns {Promise<{username: string, attributes: Object<string, string>,
     *   mfaSettings: string[], preferredMfa: string|null}>} attribute values
     *   are strings, as Cognito returns them (`email_verified` is "true").
     */
    async getUser(accessToken) {
      const data = await call('GetUser', { AccessToken: accessToken });
      const attributes = {};
      (data.UserAttributes || []).forEach(({ Name, Value }) => { attributes[Name] = Value; });
      return {
        username: data.Username || null,
        attributes,
        mfaSettings: data.UserMFASettingList || [],
        preferredMfa: data.PreferredMfaSetting || null,
      };
    },

    /**
     * Change attributes. Changing `email` makes Cognito send a code to the
     * new address, since the pool auto-verifies email.
     *
     * @param {string} accessToken
     * @param {Object<string, string>} attributes - name to value.
     * @returns {Promise<CodeDelivery[]>}
     */
    async updateUserAttributes(accessToken, attributes) {
      const data = await call('UpdateUserAttributes', {
        AccessToken: accessToken,
        UserAttributes: Object.entries(attributes).map(([Name, Value]) => ({ Name, Value })),
      });
      return (data.CodeDeliveryDetailsList || []).map(codeDelivery);
    },

    /** @returns {Promise<CodeDelivery|null>} */
    async getUserAttributeVerificationCode(accessToken, attributeName) {
      const data = await call('GetUserAttributeVerificationCode', {
        AccessToken: accessToken,
        AttributeName: attributeName,
      });
      return codeDelivery(data.CodeDeliveryDetails);
    },

    /** @returns {Promise<void>} */
    async verifyUserAttribute(accessToken, attributeName, code) {
      await call('VerifyUserAttribute', {
        AccessToken: accessToken,
        AttributeName: attributeName,
        Code: code,
      });
    },

    /**
     * Start TOTP setup.
     *
     * @param {string} accessToken
     * @returns {Promise<string>} the shared secret, base32.
     */
    async associateSoftwareToken(accessToken) {
      const data = await call('AssociateSoftwareToken', { AccessToken: accessToken });
      if (!data.SecretCode) {
        throw new CognitoError('UnreadableResponse', 'Cognito returned no authenticator secret.');
      }
      return data.SecretCode;
    },

    /**
     * Check the first code from the new authenticator. Throws when Cognito
     * does not report success, so a caller never goes on to turn MFA on
     * with an unverified token.
     *
     * @param {string} accessToken
     * @param {string} code
     * @param {string} [friendlyDeviceName]
     * @returns {Promise<void>}
     */
    async verifySoftwareToken(accessToken, code, friendlyDeviceName = 'Cabalmail') {
      const data = await call('VerifySoftwareToken', {
        AccessToken: accessToken,
        UserCode: code,
        FriendlyDeviceName: friendlyDeviceName,
      });
      if (data.Status !== 'SUCCESS') {
        throw new CognitoError('EnableSoftwareTokenMFAException', 'The code did not verify.');
      }
    },

    /**
     * Turn TOTP on (enabled and preferred) or off. SMS MFA settings are
     * left as they are.
     *
     * @param {string} accessToken
     * @param {boolean} enabled
     * @returns {Promise<void>}
     */
    async setSoftwareTokenMfa(accessToken, enabled) {
      await call('SetUserMFAPreference', {
        AccessToken: accessToken,
        SoftwareTokenMfaSettings: { Enabled: enabled, PreferredMfa: enabled },
      });
    },
  };
}

/**
 * The main client and, when configured, the enrollment client, from
 * /config.js's `cognitoConfig`. The region falls back to the pool ID's
 * prefix (us-east-1_xxxx) for a /config.js without one.
 *
 * @param {object} cognitoConfig
 * @param {object} [options] - fetchImpl / now, passed through.
 * @returns {{client: object, enrollClient: object|null}}
 */
export function clientsFromConfig(cognitoConfig, options = {}) {
  const { poolData = {}, enrollClientId } = cognitoConfig || {};
  const region = (cognitoConfig && cognitoConfig.region)
    || String(poolData.UserPoolId || '').split('_')[0];
  const client = createCognitoClient({ ...options, region, clientId: poolData.ClientId });
  const enrollClient = enrollClientId
    ? createCognitoClient({ ...options, region, clientId: enrollClientId })
    : null;
  return { client, enrollClient };
}

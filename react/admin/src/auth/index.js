/**
 * The webmail's Cognito auth: a JSON API client (cognito.js), the session
 * holder (session.js), and the error predicates and token claims the UI
 * branches on. No React in here.
 */

export { createCognitoClient, clientsFromConfig, codeDelivery } from './cognito';
export { createSession, SESSION_STORAGE_KEY } from './session';
export {
  CognitoError,
  isInvalidInvitationCode,
  isMfaEnrollmentRequired,
  isCodeMismatch,
  isNotAuthorized,
  isLimitExceeded,
  isSignInRequired,
} from './errors';
export { decodeJwtPayload, isAdminToken } from './jwt';

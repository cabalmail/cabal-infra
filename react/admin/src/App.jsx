// Third party libs

import React, { useState, useEffect, useCallback, useRef, useMemo, Suspense } from 'react';
import axios from 'axios';
import ApiClient from './ApiClient';
import {
  CognitoUser,
  CognitoUserPool,
  CognitoUserAttribute,
  AuthenticationDetails
} from 'amazon-cognito-identity-js';

// Lazy-loaded view components
const Email = React.lazy(() => import('./Email'));
const Addresses = React.lazy(() => import('./Addresses'));
const Users = React.lazy(() => import('./Users'));
const Dmarc = React.lazy(() => import('./Dmarc'));
const Caa = React.lazy(() => import('./Caa'));
const About = React.lazy(() => import('./About'));
const Security = React.lazy(() => import('./Security'));

// Pre-login Components
import SignUp from './SignUp';
import Login from './Login';
import Verify from './Verify';
import MfaChallenge from './MfaChallenge';
import MfaSetup from './MfaSetup';
import VerifyEmail from './VerifyEmail';
import EnrollMfa from './EnrollMfa';
import ForgotPassword from './ForgotPassword';
import ResetPassword from './ResetPassword';
import AuthShell from './Login/AuthShell';

// Persistent Components
import AppMessage from './AppMessage';
import Nav from './Nav';
import KeyboardHelp from './KeyboardHelp';

// Error Boundary
import ErrorBoundary from './ErrorBoundary';

// Contexts
import AuthContext from './contexts/AuthContext';
import AppMessageContext from './contexts/AppMessageContext';

// Hooks
import useTheme from './hooks/useTheme';
import useDisplayName from './hooks/useDisplayName';
import useKeyboardShortcuts from './hooks/useKeyboardShortcuts';
import useResendThrottle from './hooks/useResendThrottle';

// Site-wide and Theme-specific style.
// AppLight.css defines unconditional default tokens; AppDark.css overrides
// them inside @media (prefers-color-scheme: dark). Load light first so the
// media-gated dark rules win by source order at equal specificity.
import './AppLight.css';
import './AppDark.css';
import { ADDRESS_LIST, FOLDER_LIST, DATE, DESC } from './constants';
import { viewWhenLoggedOut } from './authViews';
import './App.css';

// Module-level token storage (never persisted to localStorage)
let _token = null;
let _expires = Math.floor(Date.now() / 1000) - 1;

// Globals
let UserPool = null;

function loadSavedState() {
  const defaults = {
    loggedIn: false,
    userName: null,
    password: null,
    email: null,
    phone: null,
    inviteCode: null,
    verificationCode: null,
    view: "Login",
    poolData: null,
    enroll_client_id: null,
    control_domain: null,
    imap_host: null,
    domains: {},
    api_url: null,
    invitation_required: false,
    sms_enabled: false,
    monitoring: false,
  };
  const saved = JSON.parse(window.localStorage.getItem('state'));
  return saved ? { ...defaults, ...saved, password: null, inviteCode: null } : defaults;
}

function persistState(state) {
  try {
    const { password, inviteCode, ...safe } = state;
    window.localStorage.setItem('state', JSON.stringify(safe));
  } catch (e) {
    console.log(e);
  }
}

/**
 * Application for reading Cabalmail email and
 * managing Cabalmail addresses and folders
 */
function App() {
  const [state, setAppState] = useState(loadSavedState);
  const [isAdmin, setIsAdmin] = useState(false);
  const [message, setMessageText] = useState(null);
  const [error, setError] = useState(false);
  const [hideMessage, setHideMessage] = useState(true);
  const [configError, setConfigError] = useState(false);
  const hideTimerRef = useRef(null);

  // ApiClient for preference hydration. Only usable once login has populated
  // `api_url` and the module-level `_token`. Re-created when those inputs
  // change so useTheme picks up the fresh token.
  const prefsApi = useMemo(() => (
    state.loggedIn && state.api_url && _token
      ? new ApiClient(state.api_url, _token, state.imap_host)
      : null
  ), [state.loggedIn, state.api_url, state.imap_host]);
  const prefs = useTheme(prefsApi);
  // Display name used by the /send Lambda as the From header's display name.
  const displayNamePref = useDisplayName(prefsApi);

  // Message-list state bags per §4c / State Management. Lifted here so that
  // future phases (reader selection, keyboard shortcuts) can read the same
  // source of truth. `selected` is a Set of numeric message IDs.
  const [filter, setFilter] = useState('all');
  const [sortKey, setSortKey] = useState(DATE);
  const [sortDir, setSortDir] = useState(DESC);
  const [bulkMode, setBulkMode] = useState(false);
  const [selected, setSelected] = useState(() => new Set());

  // Reader format preference per §4d. 'rich' renders HTML in a sandboxed
  // iframe; 'plain' falls back to the text/plain alternative. The reader
  // itself clamps to 'plain' for messages with no HTML part.
  const [readerFormat, setReaderFormat] = useState('rich');

  // Compose "From" preference per §4e. Newly-opened compose windows default
  // to this address; the From picker writes back so the next window inherits
  // the user's last choice. `null` defers to the first address the compose
  // window loads.
  const [composeFromAddress, setComposeFromAddress] = useState(null);

  // Phase 2 of `docs/0.9.x/imap-search-plan.md`: the Nav search bar commits
  // its query into `searchQuery` on Enter; the Email view swaps in the
  // Search results pane while it is non-empty. Selecting a folder, or
  // clicking Clear in the search header, sets it back to "".
  const [searchQuery, setSearchQuery] = useState('');

  // Phase 7 §3: controls the ForgotPassword success state. Set on Cognito
  // `forgotPassword` success; cleared when the user leaves the screen.
  const [forgotPasswordSent, setForgotPasswordSent] = useState(false);

  // Identity plan Phase 1. Where the signup confirmation code actually
  // went ({medium, destination} from Cognito's CodeDeliveryDetails):
  // phone when SMS is wired, email otherwise. Drives Verify's wording.
  const [signupDelivery, setSignupDelivery] = useState(null);
  // Where the password-reset code went ('email' | 'phone'), same source.
  const [forgotDelivery, setForgotDelivery] = useState(null);
  // Pending second-factor login: the CognitoUser mid-challenge (kept in a
  // ref - it is a stateful SDK object, not render state) and which
  // challenge Cognito issued ('totp' | 'sms').
  const pendingMfaUserRef = useRef(null);
  const [mfaChallengeType, setMfaChallengeType] = useState('totp');
  // Locked-out TOTP setup (#768): the CognitoUser authenticated through
  // the enrollment app client (a stateful SDK object, so a ref) and the
  // pending TOTP secret. The secret deliberately lives outside the
  // persisted state bag so it never reaches localStorage.
  const mfaSetupUserRef = useRef(null);
  const [mfaSetupSecret, setMfaSetupSecret] = useState(null);
  const [mfaSetupBusy, setMfaSetupBusy] = useState(false);
  // Post-login email gate: null when passed/skipped, else
  // { mode: 'add' | 'verify', address }. Not persisted - it is
  // re-derived from user attributes at each login.
  const [emailGate, setEmailGate] = useState(null);
  const [emailSendInFlight, setEmailSendInFlight] = useState(false);

  // "Resend code" state for Verify (signup) and ResetPassword. The
  // hook only holds the lockout signalled by Cognito's
  // LimitExceededException; the in-flight booleans here disable the
  // button while a request is on the wire so users don't double-fire.
  // See hooks/useResendThrottle.js.
  const signupResend = useResendThrottle('signup', state.userName);
  const resetResend = useResendThrottle('reset', state.userName);
  const [signupResendInFlight, setSignupResendInFlight] = useState(false);
  const [resetResendInFlight, setResetResendInFlight] = useState(false);

  // Phase 7 §Interactions: `?` toggles the keyboard-shortcut overlay.
  const [helpOpen, setHelpOpen] = useState(false);

  // Bridge for keys whose handlers live inside the Email view (compose,
  // folder navigation, j/k cursor, etc.). Child components register
  // handlers on mount; the shortcut hook proxies through this ref so
  // App doesn't need to lift Email's internals.
  const shortcutHandlersRef = useRef({});

  const setState = useCallback((updates) => {
    setAppState(prev => {
      const next = { ...prev, ...updates };
      persistState(next);
      return next;
    });
  }, []);

  const checkSession = useCallback(() => {
    if (_expires >= Math.floor(Date.now() / 1000)) return;
    if (_token !== null) {
      _token = null;
    }
    setAppState(prev => {
      const updates = {};
      const view = viewWhenLoggedOut(prev.view, !!prev.password);
      if (view !== prev.view) {
        updates.view = view;
      }
      if (prev.loggedIn !== false) {
        updates.loggedIn = false;
      }
      if (Object.keys(updates).length === 0) return prev;
      const next = { ...prev, ...updates };
      persistState(next);
      return next;
    });
  }, []);

  const setMessage = useCallback((m, e) => {
    checkSession();
    setMessageText(m);
    setError(e);
    setHideMessage(false);
    if (hideTimerRef.current) clearTimeout(hideTimerRef.current);
    hideTimerRef.current = setTimeout(() => {
      setHideMessage(true);
    }, e ? 15000 : 4000);
  }, [checkSession]);

  // Surface a friendly banner when an IMAP-backed API call returns the
  // planned-maintenance 503 (see lambda/api/_shared/helper.py maintenance_guard):
  // the IMAP tier rolls with a brief single-task outage, and without this the
  // raw 503 surfaces as a scary per-view error. We also rewrite error.message to
  // the friendly copy so any catch that displays it shows the same thing, and
  // tag error.isMaintenance for callers that want to branch on it. Non-
  // maintenance errors pass through untouched.
  useEffect(() => {
    const id = axios.interceptors.response.use(
      (response) => response,
      (error) => {
        const res = error && error.response;
        if (res && res.status === 503) {
          let body = res.data;
          if (typeof body === 'string') {
            try { body = JSON.parse(body); } catch { body = null; }
          }
          if (body && body.status === 'maintenance') {
            const friendly = body.message
              || 'Email access is temporarily unavailable due to planned maintenance.';
            setMessage(friendly, true);
            error.isMaintenance = true;
            error.message = friendly;
          }
        }
        return Promise.reject(error);
      }
    );
    return () => axios.interceptors.response.eject(id);
  }, [setMessage]);

  // Fetch config and restore session on mount.
  //
  // If the /config.js fetch fails on a first visit (no localStorage),
  // configError gates a blocking error screen below; without it the Login
  // form would render with a null UserPool and silently swallow submits.
  // Returning visits keep working from the loadSavedState snapshot.
  useEffect(() => {
    axios.get('/config.js').then(({ data }) => {
      const {
        control_domain,
        domains,
        cognitoConfig,
        invitation_required,
        sms_enabled,
        monitoring,
      } = data;
      UserPool = new CognitoUserPool(cognitoConfig.poolData);
      setState({
        poolData: cognitoConfig.poolData,
        // Absent from a pre-#768 /config.js; the locked-out MFA setup
        // flow feature-detects on it and falls back to a plain banner.
        enroll_client_id: cognitoConfig.enrollClientId || null,
        control_domain,
        imap_host: control_domain.match(/^dev\./)
          ? control_domain.replace("dev.", "imap.")
          : "imap." + control_domain,
        domains,
        api_url: "https://admin." + control_domain + "/prod",
        invitation_required: invitation_required === true,
        // Default true so an older /config.js (pre-712, no `sms_enabled` key)
        // keeps rendering the phone field and consent checkbox rather than
        // silently dropping them on a pool that still requires SMS.
        sms_enabled: sms_enabled !== false,
        monitoring: monitoring === true
      });
      const cognitoUser = UserPool.getCurrentUser();
      if (cognitoUser) {
        cognitoUser.getSession((err, session) => {
          if (err || !session || !session.isValid()) return;
          _token = session.getIdToken().getJwtToken();
          _expires = session.getIdToken().getExpiration();
          const payload = JSON.parse(atob(_token.split('.')[1]));
          const groups = payload['cognito:groups'] || [];
          setIsAdmin(groups.includes('admin'));
          setState({ loggedIn: true, view: "Email" });
        });
      }
    }).catch((err) => {
      console.error('Failed to load runtime config from /config.js', err);
      setConfigError(true);
    });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // Check session on window focus
  useEffect(() => {
    window.addEventListener("focus", checkSession);
    return () => window.removeEventListener("focus", checkSession);
  }, [checkSession]);

  // Cross-cutting About navigation. AuthShell's footer dispatches this
  // event so pre-login screens can route to About without threading an
  // onAbout callback through every auth view.
  useEffect(() => {
    const onShowAbout = () => setState({ view: "About" });
    window.addEventListener("cabal:show-about", onShowAbout);
    return () => window.removeEventListener("cabal:show-about", onShowAbout);
  }, [setState]);

  // Check session on every render (mirrors componentDidUpdate)
  useEffect(() => {
    checkSession();
  });

  // Clean up message timer on unmount
  useEffect(() => {
    return () => {
      if (hideTimerRef.current) clearTimeout(hideTimerRef.current);
    };
  }, []);

  // Bounce non-admins away from admin-only views (e.g. "Addresses" persisted
  // in localStorage from a prior admin session, or a deep-link).
  useEffect(() => {
    const adminOnlyViews = ["Addresses", "Users", "DMARC", "CAA"];
    if (state.loggedIn && !isAdmin && adminOnlyViews.includes(state.view)) {
      setState({ view: "Email" });
    }
  }, [state.loggedIn, state.view, isAdmin, setState]);

  const doRegister = useCallback((e) => {
    e.preventDefault();
    const attributes = [
      new CognitoUserAttribute({
        Name: 'preferred_username',
        Value: state.userName
      }),
      // Recovery email (identity plan Phase 1). Always collected; the
      // pool auto-verifies it, so Cognito emails a code either at signup
      // (SMS off - email is the only channel) or via the post-login
      // VerifyEmail gate (SMS on - the signup code goes to the phone).
      new CognitoUserAttribute({
        Name: 'email',
        Value: state.email
      }),
    ];
    // Phone number is only collected when the pool is wired for SMS
    // (a 10DLC campaign registration id is configured). See issue #712
    // and terraform/infra/modules/user_pool/main.tf.
    if (state.sms_enabled && state.phone) {
      attributes.push(new CognitoUserAttribute({
        Name: 'phone_number',
        Value: state.phone
      }));
    }
    // Shared-secret invitation code, validated by the check_invite
    // Cognito pre-signup Lambda. Passed via validationData so it never
    // lands on the user record. Key must match the Python handler.
    const validationData = [new CognitoUserAttribute({
      Name: 'invitationCode',
      Value: state.inviteCode || ''
    })];
    UserPool.signUp(
      state.userName,
      state.password,
      attributes,
      validationData,
      (err, result) => {
        if (!err) {
          // Let Cognito say where the confirmation code went rather than
          // assuming. No delivery details means no code was sent at all:
          // with SMS off, the check_invite pre-signup trigger auto-confirms
          // the account (issue #712), so there is nothing to verify here -
          // email verification happens at first sign-in instead.
          const details = result && result.codeDeliveryDetails;
          if (!details) {
            setState({ view: "Login", inviteCode: null });
            setMessage(
              "Account created. It is pending admin approval; you'll be notified when it is ready.",
              false
            );
            return;
          }
          const medium = details.DeliveryMedium === 'EMAIL' ? 'email' : 'phone';
          setSignupDelivery({
            medium,
            destination: details.Destination || null,
          });
          setState({ view: "Verify", inviteCode: null });
          setMessage(`Check your ${medium} for a verification code.`, false);
        } else {
          setState({ view: "SignUp" });
          const msg = /invitation code/i.test(err.message || '')
            ? "Invalid invitation code."
            : "Registration failed.";
          setMessage(msg, true);
        }
      }
    );
  }, [state.userName, state.password, state.email, state.phone, state.inviteCode, state.sms_enabled, setState, setMessage]);

  const doVerify = useCallback((e) => {
    e.preventDefault();
    const cognitoUser = new CognitoUser({
      Username: state.userName,
      Pool: UserPool
    });
    cognitoUser.confirmRegistration(state.verificationCode, true, (err, _result) => {
      if (!err) {
        signupResend.reset();
        const which = signupDelivery && signupDelivery.medium === 'email' ? 'Email' : 'Phone';
        setState({ view: "Login", verificationCode: null });
        setMessage(`${which} verified. Your account is pending admin approval.`, false);
      } else {
        setMessage("Verification failed. Please check your code and try again.", true);
      }
    });
  }, [state.userName, state.verificationCode, signupDelivery, setState, setMessage, signupResend]);

  const doResendVerification = useCallback(() => {
    if (signupResend.locked || signupResendInFlight || !state.userName) return;
    setSignupResendInFlight(true);
    const cognitoUser = new CognitoUser({
      Username: state.userName,
      Pool: UserPool
    });
    cognitoUser.resendConfirmationCode((err, result) => {
      setSignupResendInFlight(false);
      if (!err) {
        const details = result && result.CodeDeliveryDetails;
        const medium = details && details.DeliveryMedium === 'EMAIL' ? 'email' : 'phone';
        setMessage(`A new verification code has been sent to your ${medium}.`, false);
        return;
      }
      // Cognito hit its per-user resend limit. Mirror the lockout in
      // local state so the UI stops offering Resend until the window
      // passes; the message echoes Cognito rather than inventing a
      // schedule.
      if (err.code === 'LimitExceededException' || err.name === 'LimitExceededException') {
        signupResend.recordLimitHit();
        setMessage("Too many resend attempts. Please try again later.", true);
      } else {
        setMessage("Could not resend code. Please try again later.", true);
      }
    });
  }, [state.userName, signupResend, signupResendInFlight, setMessage]);

  const doForgotPassword = useCallback((e) => {
    e.preventDefault();
    const cognitoUser = new CognitoUser({
      Username: state.userName,
      Pool: UserPool
    });
    // Recovery is email-first now (identity plan Phase 1); read where
    // Cognito actually sent the code instead of hardcoding "phone".
    const sentTo = (data) => {
      const details = data && data.CodeDeliveryDetails;
      const medium = details && details.DeliveryMedium === 'EMAIL' ? 'email' : 'phone';
      setForgotDelivery(medium);
      setForgotPasswordSent(true);
      setMessage(`A reset code has been sent to your ${medium}.`, false);
    };
    cognitoUser.forgotPassword({
      onSuccess: sentTo,
      onFailure: () => {
        setMessage("Failed to send reset code. Please try again.", true);
      },
      inputVerificationCode: sentTo
    });
  }, [state.userName, setMessage]);

  const doResendResetCode = useCallback(() => {
    if (resetResend.locked || resetResendInFlight || !state.userName) return;
    setResetResendInFlight(true);
    const cognitoUser = new CognitoUser({
      Username: state.userName,
      Pool: UserPool
    });
    const sentTo = (data) => {
      const details = data && data.CodeDeliveryDetails;
      const medium = details && details.DeliveryMedium === 'EMAIL' ? 'email' : 'phone';
      setForgotDelivery(medium);
      setResetResendInFlight(false);
      setMessage(`A new reset code has been sent to your ${medium}.`, false);
    };
    cognitoUser.forgotPassword({
      onSuccess: sentTo,
      onFailure: (err) => {
        setResetResendInFlight(false);
        if (err && (err.code === 'LimitExceededException' || err.name === 'LimitExceededException')) {
          resetResend.recordLimitHit();
          setMessage("Too many resend attempts. Please try again later.", true);
        } else {
          setMessage("Could not resend code. Please try again later.", true);
        }
      },
      inputVerificationCode: sentTo
    });
  }, [state.userName, resetResend, resetResendInFlight, setMessage]);

  const doResetPassword = useCallback((e) => {
    e.preventDefault();
    const cognitoUser = new CognitoUser({
      Username: state.userName,
      Pool: UserPool
    });
    cognitoUser.confirmPassword(state.verificationCode, state.password, {
      onSuccess: () => {
        resetResend.reset();
        setState({ view: "Login", verificationCode: null, password: null });
        setMessage("Password reset successful. You can now log in.", false);
      },
      onFailure: () => {
        setMessage("Password reset failed. Please check your code and try again.", true);
      }
    });
  }, [state.userName, state.verificationCode, state.password, setState, setMessage, resetResend]);

  // Run a callback against the signed-in CognitoUser with a fresh
  // session attached. The SDK requires getSession before any
  // user-attribute or MFA API call.
  const withCurrentUser = useCallback((fn, onUnavailable) => {
    const cognitoUser = UserPool && UserPool.getCurrentUser();
    if (!cognitoUser) {
      if (onUnavailable) onUnavailable();
      return;
    }
    cognitoUser.getSession((err, session) => {
      if (err || !session || !session.isValid()) {
        if (onUnavailable) onUnavailable();
        return;
      }
      fn(cognitoUser);
    });
  }, []);

  // Shared tail of every successful authentication (password-only or
  // after an MFA challenge). Lands on the Email view unless the account
  // is missing a verified recovery email (VerifyEmail gate) or has no
  // MFA factor (EnrollMfa nudge; the server-side user gate in
  // require_admin_mfa will eventually enforce what this screen asks
  // for). One gate per sign-in, email first. Both checks are advisory:
  // a metadata-read failure must never block an otherwise-good login.
  // mfaVerified skips the enrollment probe when the login itself just
  // answered a TOTP challenge - that user is enrolled by definition.
  const finishLogin = useCallback((data, user, mfaVerified = false) => {
    _token = data.getIdToken().getJwtToken();
    _expires = data.getIdToken().getExpiration();
    const payload = JSON.parse(atob(_token.split('.')[1]));
    const groups = payload['cognito:groups'] || [];
    setIsAdmin(groups.includes('admin'));
    pendingMfaUserRef.current = null;
    user.getUserAttributes((err, attrs) => {
      let next = { loggedIn: true, view: "Email" };
      if (!err && attrs) {
        const byName = {};
        attrs.forEach((a) => { byName[a.getName()] = a.getValue(); });
        if (!byName.email) {
          setEmailGate({ mode: 'add', address: null });
          next = { loggedIn: true, view: "VerifyEmail", email: null };
        } else if (byName.email_verified !== 'true') {
          setEmailGate({ mode: 'verify', address: byName.email });
          next = { loggedIn: true, view: "VerifyEmail", verificationCode: null };
        }
      }
      if (mfaVerified || next.view !== "Email") {
        setState(next);
        setMessage("Login succeeded", false);
        return;
      }
      user.getUserData((mfaErr, userData) => {
        const enrolled = !mfaErr &&
          ((userData && userData.UserMFASettingList) || []).includes('SOFTWARE_TOKEN_MFA');
        // Fail open on a read error: nudging is not worth blocking a
        // login over.
        setState(mfaErr || enrolled
          ? next
          : { loggedIn: true, view: "EnrollMfa" });
        setMessage("Login succeeded", false);
      }, { bypassCache: true });
    });
  }, [setState, setMessage]);

  const doLogin = useCallback((e) => {
    e.preventDefault();
    const user = new CognitoUser({
      Username: state.userName,
      Pool: UserPool
    });
    const creds = new AuthenticationDetails({
      Username: state.userName,
      Password: state.password
    });
    user.authenticateUser(creds, {
      onSuccess: data => finishLogin(data, user),
      onFailure: (err) => {
        _token = null;
        _expires = Math.floor(new Date() / 1000) - 1;
        // The require_admin_mfa pre-token-generation trigger (enforce
        // mode) rejects any un-enrolled account. Route to the
        // self-service setup flow (#768) when the enrollment client is
        // configured; otherwise surface an actionable banner.
        const mfaBlocked = err && /require.*multi-factor|admin accounts require/i.test(err.message || '');
        if (mfaBlocked && state.enroll_client_id) {
          setMfaSetupSecret(null);
          setState({ loggedIn: false, view: "MfaSetup" });
          return;
        }
        setState({ loggedIn: false, view: "Login" });
        setMessage(
          mfaBlocked
            ? "This account requires multi-factor authentication. Contact the operator to restore access."
            : "Login failed",
          true
        );
      },
      // Second-factor challenges (identity plan Phase 1). The CognitoUser
      // carries the challenge session, so it is parked in a ref until the
      // MfaChallenge screen submits the code.
      totpRequired: () => {
        pendingMfaUserRef.current = user;
        setMfaChallengeType('totp');
        setState({ view: "MfaChallenge", verificationCode: null });
      },
      mfaRequired: () => {
        pendingMfaUserRef.current = user;
        setMfaChallengeType('sms');
        setState({ view: "MfaChallenge", verificationCode: null });
      }
    });
  }, [state.userName, state.password, state.enroll_client_id, finishLogin, setState, setMessage]);

  const doSubmitMfaCode = useCallback((e) => {
    e.preventDefault();
    const user = pendingMfaUserRef.current;
    if (!user) {
      // The challenge session lives only in memory; a reload mid-challenge
      // loses it and the login must restart.
      setState({ view: "Login", verificationCode: null });
      setMessage("Your sign-in session expired. Please log in again.", true);
      return;
    }
    user.sendMFACode(
      state.verificationCode,
      {
        onSuccess: (data) => finishLogin(data, user, true),
        onFailure: () => {
          setMessage("That code did not match. Please try again.", true);
        }
      },
      mfaChallengeType === 'totp' ? 'SOFTWARE_TOKEN_MFA' : 'SMS_MFA'
    );
  }, [state.verificationCode, mfaChallengeType, finishLogin, setState, setMessage]);

  // --- Locked-out TOTP setup handlers (#768) ---
  //
  // The gate rejects password logins for un-enrolled accounts, so the
  // normal client can never yield a session to enroll with. These
  // re-authenticate through the dedicated enrollment app client
  // (enrollClientId from /config.js), which the gate passes for
  // factorless users only, then run the same associate/verify/prefer
  // sequence as the Security view against that short-lived session.

  const beginMfaSetup = useCallback(() => {
    if (!state.poolData || !state.enroll_client_id || !state.userName || !state.password) {
      // The password never survives a reload (persistState strips it),
      // so a revisit of this view has to restart from Login.
      setState({ view: "Login" });
      setMessage("Please enter your password again to continue.", true);
      return;
    }
    const pool = new CognitoUserPool({
      UserPoolId: state.poolData.UserPoolId,
      ClientId: state.enroll_client_id,
    });
    const user = new CognitoUser({ Username: state.userName, Pool: pool });
    const creds = new AuthenticationDetails({
      Username: state.userName,
      Password: state.password,
    });
    // Only an already-enrolled account draws a second-factor challenge
    // here; normal sign-in is the right path for it.
    const alreadyEnrolled = () => {
      setMfaSetupBusy(false);
      setState({ view: "Login" });
      setMessage("This account already has an authenticator. Sign in normally.", true);
    };
    setMfaSetupBusy(true);
    user.authenticateUser(creds, {
      onSuccess: () => {
        user.associateSoftwareToken({
          associateSecretCode: (secret) => {
            setMfaSetupBusy(false);
            mfaSetupUserRef.current = user;
            setMfaSetupSecret(secret);
            setState({ verificationCode: null });
          },
          onFailure: () => {
            setMfaSetupBusy(false);
            setMessage("Could not start two-factor setup. Please try again.", true);
          },
        });
      },
      onFailure: () => {
        setMfaSetupBusy(false);
        setMessage("Could not start two-factor setup. Please try again.", true);
      },
      totpRequired: alreadyEnrolled,
      mfaRequired: alreadyEnrolled,
    });
  }, [state.poolData, state.enroll_client_id, state.userName, state.password, setState, setMessage]);

  const doConfirmMfaSetup = useCallback((e) => {
    e.preventDefault();
    const user = mfaSetupUserRef.current;
    if (!user) {
      // The enrollment session lives only in memory; a reload mid-setup
      // loses it and the flow must restart.
      setMfaSetupSecret(null);
      setState({ view: "Login", verificationCode: null });
      setMessage("Your setup session expired. Please log in again.", true);
      return;
    }
    setMfaSetupBusy(true);
    user.verifySoftwareToken(state.verificationCode, 'Cabalmail', {
      onSuccess: () => {
        user.setUserMfaPreference(
          null,
          { PreferredMfa: true, Enabled: true },
          (err) => {
            setMfaSetupBusy(false);
            if (err) {
              setMessage("Could not turn on two-factor authentication. Please try again.", true);
              return;
            }
            // Drop the enrollment-client session; the normal sign-in
            // (which now issues a TOTP challenge) is what counts.
            mfaSetupUserRef.current = null;
            user.signOut();
            setMfaSetupSecret(null);
            setState({ view: "Login", verificationCode: null });
            setMessage("Two-factor authentication is on. Sign in again with a code from your app.", false);
          }
        );
      },
      onFailure: () => {
        setMfaSetupBusy(false);
        setMessage("That code did not match. Check your authenticator app and try again.", true);
      },
    });
  }, [state.verificationCode, setState, setMessage]);

  const cancelMfaSetup = useCallback((e) => {
    e.preventDefault();
    const user = mfaSetupUserRef.current;
    if (user) user.signOut();
    mfaSetupUserRef.current = null;
    setMfaSetupSecret(null);
    setMfaSetupBusy(false);
    setState({ view: "Login", verificationCode: null });
  }, [setState]);

  // --- VerifyEmail gate handlers (identity plan Phase 1) ---

  // "add" mode: save the address. The pool auto-verifies email, so
  // updateAttributes makes Cognito send the verification code itself.
  const doSaveRecoveryEmail = useCallback((e) => {
    e.preventDefault();
    const address = state.email;
    if (!address) return;
    withCurrentUser((user) => {
      const attr = new CognitoUserAttribute({ Name: 'email', Value: address });
      user.updateAttributes([attr], (err) => {
        if (err) {
          setMessage("Could not save that address. Please try again.", true);
          return;
        }
        setEmailGate({ mode: 'verify', address });
        setState({ verificationCode: null });
        setMessage(`A verification code has been sent to ${address}.`, false);
      });
    }, () => setMessage("Your session expired. Please log in again.", true));
  }, [state.email, withCurrentUser, setState, setMessage]);

  const doSendEmailCode = useCallback(() => {
    if (emailSendInFlight) return;
    setEmailSendInFlight(true);
    withCurrentUser((user) => {
      user.getAttributeVerificationCode('email', {
        inputVerificationCode: () => {
          setEmailSendInFlight(false);
          setMessage("A verification code has been sent to your email.", false);
        },
        onFailure: (err) => {
          setEmailSendInFlight(false);
          const limited = err && (err.code === 'LimitExceededException' || err.name === 'LimitExceededException');
          setMessage(
            limited
              ? "Too many attempts. Please try again later."
              : "Could not send a code. Please try again later.",
            true
          );
        }
      });
    }, () => {
      setEmailSendInFlight(false);
      setMessage("Your session expired. Please log in again.", true);
    });
  }, [emailSendInFlight, withCurrentUser, setMessage]);

  const doVerifyEmailCode = useCallback((e) => {
    e.preventDefault();
    withCurrentUser((user) => {
      user.verifyAttribute('email', state.verificationCode, {
        onSuccess: () => {
          setEmailGate(null);
          setState({ view: "Email", verificationCode: null });
          setMessage("Email verified. It can now be used for account recovery.", false);
        },
        onFailure: () => {
          setMessage("Verification failed. Please check your code and try again.", true);
        }
      });
    }, () => setMessage("Your session expired. Please log in again.", true));
  }, [state.verificationCode, withCurrentUser, setState, setMessage]);

  const skipEmailGate = useCallback((e) => {
    e.preventDefault();
    setEmailGate(null);
    setState({ view: "Email" });
  }, [setState]);

  // TOTP enrollment surface for the Security view. Thin wrappers so the
  // Cognito SDK stays in App (where UserPool lives) and the view can be
  // tested with a mock.
  const mfaApi = useMemo(() => ({
    getStatus: (cb) => withCurrentUser(
      (user) => user.getUserData((err, data) => {
        if (err) { cb(err); return; }
        cb(null, (data.UserMFASettingList || []).includes('SOFTWARE_TOKEN_MFA'));
      }, { bypassCache: true }),
      () => cb(new Error('no session'))
    ),
    beginEnroll: (callbacks) => withCurrentUser(
      (user) => user.associateSoftwareToken(callbacks),
      () => callbacks.onFailure(new Error('no session'))
    ),
    confirmEnroll: (code, callbacks) => withCurrentUser(
      (user) => user.verifySoftwareToken(code, 'Cabalmail', {
        onSuccess: () => {
          user.setUserMfaPreference(
            null,
            { PreferredMfa: true, Enabled: true },
            (err) => err ? callbacks.onFailure(err) : callbacks.onSuccess()
          );
        },
        onFailure: callbacks.onFailure,
      }),
      () => callbacks.onFailure(new Error('no session'))
    ),
    disable: (cb) => withCurrentUser(
      (user) => user.setUserMfaPreference(
        null,
        { PreferredMfa: false, Enabled: false },
        cb
      ),
      () => cb(new Error('no session'))
    ),
  }), [withCurrentUser]);

  const doLogout = useCallback((e) => {
    e.preventDefault();
    _token = null;
    _expires = Math.floor(new Date() / 1000) - 1;
    if (UserPool) {
      const cognitoUser = UserPool.getCurrentUser();
      if (cognitoUser) cognitoUser.signOut();
    }
    localStorage.removeItem(ADDRESS_LIST);
    localStorage.removeItem(FOLDER_LIST);
    setIsAdmin(false);
    pendingMfaUserRef.current = null;
    setEmailGate(null);
    setSignupDelivery(null);
    setState({ loggedIn: false, userName: null, password: null, view: "Login" });
  }, [setState]);

  const doInputChange = useCallback((e) => {
    e.preventDefault();
    setState({ [e.target.name]: e.target.value });
  }, [setState]);

  const updateView = useCallback((e) => {
    e.preventDefault();
    setState({ view: e.target.name });
  }, [setState]);

  const configUnavailable = configError && !state.poolData;

  function renderContent() {
    if (configUnavailable) {
      return (
        <AuthShell>
          <h1>Cabalmail is unavailable</h1>
          <p>
            The app couldn&apos;t load its configuration. Please refresh the
            page or try again in a few minutes.
          </p>
        </AuthShell>
      );
    }
    switch (state.view) {
      case "About":
        return (
          <ErrorBoundary name="About">
            <About
              loggedIn={state.loggedIn}
              onBackToLogin={(e) => { e.preventDefault(); setState({ view: "Login" }); }}
            />
          </ErrorBoundary>
        );
      case "Users":
        return (
          <ErrorBoundary name="Users">
            <Users domains={state.domains} />
          </ErrorBoundary>
        );
      case "DMARC":
        return (
          <ErrorBoundary name="DMARC">
            <Dmarc />
          </ErrorBoundary>
        );
      case "CAA":
        return (
          <ErrorBoundary name="CAA">
            <Caa />
          </ErrorBoundary>
        );
      case "Addresses":
        return (
          <ErrorBoundary name="Addresses">
            <Addresses
              domains={state.domains}
              setMessage={setMessage}
            />
          </ErrorBoundary>
        );
      case "Verify":
        return (
          <Verify
            onSubmit={doVerify}
            onCodeChange={doInputChange}
            code={state.verificationCode}
            onBackToSignIn={(e) => { e.preventDefault(); setState({ view: "Login" }); }}
            onResend={doResendVerification}
            resendInFlight={signupResendInFlight}
            resendLocked={signupResend.locked}
            resendLockoutRemaining={signupResend.lockoutRemaining}
            medium={(signupDelivery && signupDelivery.medium) || 'phone'}
            destination={signupDelivery && signupDelivery.destination}
          />
        );
      case "MfaChallenge":
        return (
          <MfaChallenge
            onSubmit={doSubmitMfaCode}
            onCodeChange={doInputChange}
            code={state.verificationCode}
            mfaType={mfaChallengeType}
            onBackToSignIn={(e) => { e.preventDefault(); setState({ view: "Login", verificationCode: null }); }}
          />
        );
      case "VerifyEmail":
        // The gate is memory-only; a reload lands here with no gate
        // context. The mount-time session restore redirects to Email, so
        // just render nothing for that frame.
        if (!emailGate) return null;
        return (
          <VerifyEmail
            mode={emailGate.mode}
            address={emailGate.address}
            email={state.email}
            onEmailChange={doInputChange}
            onSaveEmail={doSaveRecoveryEmail}
            onSubmit={doVerifyEmailCode}
            onCodeChange={doInputChange}
            code={state.verificationCode}
            onSendCode={doSendEmailCode}
            sendInFlight={emailSendInFlight}
            onChangeEmail={(e) => {
              e.preventDefault();
              setEmailGate({ mode: 'add', address: null });
              setState({ email: null });
            }}
            onSkip={skipEmailGate}
          />
        );
      case "MfaSetup":
        return (
          <MfaSetup
            userName={state.userName}
            secret={mfaSetupSecret}
            busy={mfaSetupBusy}
            code={state.verificationCode}
            onBegin={beginMfaSetup}
            onCodeChange={doInputChange}
            onSubmit={doConfirmMfaSetup}
            onCancel={cancelMfaSetup}
          />
        );
      case "EnrollMfa":
        return (
          <EnrollMfa
            onSetUp={() => setState({ view: "Security" })}
            onLater={(e) => { e.preventDefault(); setState({ view: "Email" }); }}
          />
        );
      case "Security":
        return (
          <ErrorBoundary name="Security">
            <Security
              userName={state.userName}
              mfaApi={mfaApi}
              setMessage={setMessage}
            />
          </ErrorBoundary>
        );
      case "ForgotPassword":
        return (
          <ForgotPassword
            onSubmit={doForgotPassword}
            onUsernameChange={doInputChange}
            username={state.userName}
            submitted={forgotPasswordSent}
            deliveryMedium={forgotDelivery}
            onBackToSignIn={(e) => {
              e.preventDefault();
              setForgotPasswordSent(false);
              setState({ view: "Login" });
            }}
            onProceed={(e) => {
              e.preventDefault();
              setForgotPasswordSent(false);
              setState({ view: "ResetPassword" });
            }}
          />
        );
      case "ResetPassword":
        return (
          <ResetPassword
            onSubmit={doResetPassword}
            onCodeChange={doInputChange}
            onPasswordChange={doInputChange}
            code={state.verificationCode}
            password={state.password}
            onBackToSignIn={(e) => { e.preventDefault(); setState({ view: "Login" }); }}
            onResend={doResendResetCode}
            resendInFlight={resetResendInFlight}
            resendLocked={resetResend.locked}
            resendLockoutRemaining={resetResend.lockoutRemaining}
          />
        );
      case "SignUp":
        return (
          <SignUp
            onSubmit={doRegister}
            onUsernameChange={doInputChange}
            onEmailChange={doInputChange}
            onPhoneChange={doInputChange}
            onPasswordChange={doInputChange}
            onInviteCodeChange={doInputChange}
            username={state.userName}
            password={state.password}
            email={state.email}
            phone={state.phone}
            inviteCode={state.inviteCode}
            onSignIn={(e) => { e.preventDefault(); setState({ view: "Login" }); }}
          />
        );
      case "Email":
        return (
          <ErrorBoundary name="Email">
            <Email
              token={_token}
              api_url={state.api_url}
              host={state.imap_host}
              smtp_host={`smtp-out.${state.control_domain}`}
              domains={state.domains}
              setMessage={setMessage}
              filter={filter}
              setFilter={setFilter}
              sortKey={sortKey}
              setSortKey={setSortKey}
              sortDir={sortDir}
              setSortDir={setSortDir}
              bulkMode={bulkMode}
              setBulkMode={setBulkMode}
              selected={selected}
              setSelected={setSelected}
              readerFormat={readerFormat}
              setReaderFormat={setReaderFormat}
              composeFromAddress={composeFromAddress}
              setComposeFromAddress={setComposeFromAddress}
              searchQuery={searchQuery}
              setSearchQuery={setSearchQuery}
              shortcutHandlersRef={shortcutHandlersRef}
            />
          </ErrorBoundary>
        );
      case "Logout":
      case "Login":
      default:
        return (
          <Login
            onSubmit={doLogin}
            onUsernameChange={doInputChange}
            onPasswordChange={doInputChange}
            username={state.userName}
            password={state.password}
            onForgotPassword={(e) => { e.preventDefault(); setForgotPasswordSent(false); setState({ view: "ForgotPassword" }); }}
            onSignUp={(e) => { e.preventDefault(); setState({ view: "SignUp" }); }}
          />
        );
    }
  }

  const authValue = {
    token: _token,
    api_url: state.api_url,
    host: state.imap_host,
    smtp_host: `smtp-out.${state.control_domain}`,
    control_domain: state.control_domain,
    domains: state.domains,
    invitation_required: state.invitation_required,
    sms_enabled: state.sms_enabled
  };

  // VerifyEmail and EnrollMfa are post-login but render as focused
  // AuthShell gates (no Nav), so they live in this list alongside the
  // true pre-login views.
  const isPreLoginView = configUnavailable
    || ["Login", "SignUp", "Verify", "MfaChallenge", "MfaSetup", "VerifyEmail",
      "EnrollMfa", "ForgotPassword", "ResetPassword"].includes(state.view);

  const shortcutCallbacks = useMemo(() => ({
    onToggleHelp: () => setHelpOpen(prev => !prev),
    onFocusSearch: () => {
      const el = document.querySelector('.nav__search-input');
      if (el && el.focus) el.focus();
    },
    onEscape: () => {
      setHelpOpen(false);
      if (bulkMode) setBulkMode(false);
      shortcutHandlersRef.current.onEscape?.();
    },
    onToggleBulk: () => setBulkMode(prev => !prev),
    onCompose:    () => shortcutHandlersRef.current.onCompose?.(),
    onGoToFolder: (f) => shortcutHandlersRef.current.onGoToFolder?.(f),
    onNext:       () => shortcutHandlersRef.current.onNext?.(),
    onPrev:       () => shortcutHandlersRef.current.onPrev?.(),
    onOpen:       () => shortcutHandlersRef.current.onOpen?.(),
    onArchive:    () => shortcutHandlersRef.current.onArchive?.(),
    onDelete:     () => shortcutHandlersRef.current.onDelete?.(),
    onReply:      () => shortcutHandlersRef.current.onReply?.(),
    onReplyAll:   () => shortcutHandlersRef.current.onReplyAll?.(),
    onForward:    () => shortcutHandlersRef.current.onForward?.(),
    onFlag:       () => shortcutHandlersRef.current.onFlag?.(),
    onMarkUnread: () => shortcutHandlersRef.current.onMarkUnread?.(),
  }), [bulkMode]);

  useKeyboardShortcuts(shortcutCallbacks, state.loggedIn && !isPreLoginView);

  return (
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage }}>
        <div className={`App ${state.view}${isPreLoginView ? ' pre-login' : ''}`}>
          {!isPreLoginView && (
            <Nav
              onClick={updateView}
              loggedIn={state.loggedIn}
              view={state.view}
              doLogout={doLogout}
              isAdmin={isAdmin}
              userName={state.userName}
              accent={prefs.accent}
              onSelectAccent={prefs.setAccent}
              accents={prefs.accents}
              displayName={displayNamePref.name}
              onChangeDisplayName={displayNamePref.setName}
              searchQuery={searchQuery}
              onSearchSubmit={setSearchQuery}
              controlDomain={state.control_domain}
              monitoring={state.monitoring}
            />
          )}
          <div className="content">
            <Suspense fallback={<div className="loading">Loading...</div>}>
              {renderContent()}
            </Suspense>
          </div>
          <AppMessage
            message={message}
            hide={hideMessage}
            error={error}
          />
          <KeyboardHelp open={helpOpen} onClose={() => setHelpOpen(false)} />
        </div>
      </AppMessageContext.Provider>
    </AuthContext.Provider>
  );
}

export default App;

// Third party libs

import React, { useState, useEffect, useCallback, useRef, useMemo, Suspense } from 'react';
import axios from 'axios';
import ApiClient from './ApiClient';

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
import './tokens.css';
import { DATE, DESC } from './constants';
import { clearListCaches } from './utils/listCache';
import { viewWhenLoggedOut } from './authViews';
import { signUpErrorMessage } from './SignUp/signUpError';
import {
  clientsFromConfig,
  createSession,
  hasStoredSession,
  purgeLibraryStorage,
  decodeJwtPayload,
  isMfaEnrollmentRequired,
  isNotAuthorized,
  isLimitExceeded,
} from './auth';
import './App.css';

// How often a signed-in app checks its tokens. The session holder
// refreshes them five minutes before they expire, so an idle tab keeps a
// usable token without waiting for a focus or a render.
const SESSION_CHECK_MS = 60 * 1000;

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
  if (!saved) return defaults;
  // Whether anyone is signed in is the session's to say (src/auth): a
  // reload restores it from sessionStorage, and a new tab starts signed
  // out whatever the last tab left in this bag.
  return {
    ...defaults,
    ...saved,
    password: null,
    inviteCode: null,
    loggedIn: false,
    view: viewWhenLoggedOut(saved.view || defaults.view, false),
  };
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
  const [message, setMessageText] = useState(null);
  const [error, setError] = useState(false);
  const [hideMessage, setHideMessage] = useState(true);
  const [configError, setConfigError] = useState(false);
  const hideTimerRef = useRef(null);

  // Cognito clients and the session holder (src/auth), built once
  // /config.js names the pool. The session keeps the ID and access tokens
  // in memory and only the refresh token in sessionStorage (auth parity
  // plan, D2). Handlers read the ref; rendering reads sessionSnap, which
  // the session updates on every sign-in, refresh and sign-out.
  const authRef = useRef(null);
  const [sessionSnap, setSessionSnap] = useState(null);
  const token = sessionSnap ? sessionSnap.idToken : null;
  const isAdmin = !!(sessionSnap && sessionSnap.isAdmin);
  // True from the first render while a reload's stored session is being
  // refreshed, so a placeholder shows instead of the sign-in form.
  const [restoring, setRestoring] = useState(hasStoredSession);

  // ApiClient for preference hydration. Only usable once login has populated
  // `api_url` and the session has a token. Re-created when those inputs
  // change so useTheme picks up a refreshed token.
  const prefsApi = useMemo(() => (
    state.loggedIn && state.api_url && token
      ? new ApiClient(state.api_url, token, state.imap_host)
      : null
  ), [state.loggedIn, state.api_url, state.imap_host, token]);
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
  // Pending second-factor login: the challenge Cognito issued (its
  // Session and the user it resolved; memory-only, so a reload restarts
  // the sign-in) and which kind it is ('totp' | 'sms').
  const pendingMfaRef = useRef(null);
  const [mfaChallengeType, setMfaChallengeType] = useState('totp');
  // Locked-out TOTP setup (#768): the access token from signing in
  // through the enrollment app client, and the pending TOTP secret. Both
  // live outside the persisted state bag so neither reaches localStorage.
  const mfaSetupRef = useRef(null);
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

  // With a session, make sure its tokens are good: idToken() refreshes
  // them when they are within five minutes of expiring. A refresh that
  // fails for want of a network is retried at the next check; one Cognito
  // refuses ends the session, and the next check, finding none, falls
  // through to sign the app out.
  const checkSession = useCallback(() => {
    const auth = authRef.current;
    if (auth && auth.session.current()) {
      auth.session.idToken().catch(() => {});
      return;
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
  // form would render with no Cognito client to submit to.
  //
  // Once per app: a development build (React.StrictMode) runs mount
  // effects twice, and a second pass here would build a second session
  // that refreshes on its own, leaving two token holders of which only
  // one is the one handlers and sign-out reach. Refs survive StrictMode's
  // simulated remount, so the guard holds.
  const bootstrappedRef = useRef(false);
  useEffect(() => {
    if (bootstrappedRef.current) return;
    bootstrappedRef.current = true;
    // The tokens amazon-cognito-identity-js left in localStorage; nothing
    // reads them now, and D2 keeps no token there.
    purgeLibraryStorage();
    axios.get('/config.js').then(({ data }) => {
      const {
        control_domain,
        domains,
        cognitoConfig,
        invitation_required,
        sms_enabled,
        monitoring,
      } = data;
      const clients = clientsFromConfig(cognitoConfig);
      const session = createSession({ client: clients.client });
      // Subscribed before anything can sign in, and for the app's life.
      session.subscribe(setSessionSnap);
      authRef.current = { ...clients, session };
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
      // `restoring` is the first render's value; this effect runs once.
      if (!restoring) return;
      // A reload in this tab: trade the stored refresh token for fresh
      // tokens. On success the app is signed in as before. On a refusal
      // (null) or with Cognito out of reach it shows the sign-in form,
      // and in the second case keeps the stored token for the next reload.
      session.restore().then((snap) => {
        if (snap) {
          setState({
            loggedIn: true,
            view: "Email",
            ...(snap.username ? { userName: snap.username } : {}),
          });
        }
        setRestoring(false);
      }, (err) => {
        console.error('[auth] could not restore the session', err);
        setRestoring(false);
      });
    }).catch((err) => {
      console.error('Failed to load runtime config from /config.js', err);
      setConfigError(true);
      setRestoring(false);
    });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // Check session on window focus
  useEffect(() => {
    window.addEventListener("focus", checkSession);
    return () => window.removeEventListener("focus", checkSession);
  }, [checkSession]);

  // ...and on a timer while signed in, so a tab nobody touches refreshes
  // its tokens before they expire rather than on the first click after.
  useEffect(() => {
    if (!state.loggedIn) return undefined;
    const id = setInterval(checkSession, SESSION_CHECK_MS);
    return () => clearInterval(id);
  }, [state.loggedIn, checkSession]);

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

  // The Cognito clients, or a banner when there are none: /config.js
  // hasn't arrived yet, or (on a returning visit, which still renders
  // the form from the saved state bag) it failed to load.
  const requireAuth = useCallback(() => {
    if (authRef.current) return authRef.current;
    setMessage(
      configError
        ? "Cabalmail couldn't load its configuration. Please refresh the page."
        : "Cabalmail is still loading. Please try again in a moment.",
      true
    );
    return null;
  }, [configError, setMessage]);

  const doRegister = useCallback((e) => {
    e.preventDefault();
    const auth = requireAuth();
    if (!auth) return;
    auth.client.signUp({
      username: state.userName,
      password: state.password,
      // Recovery email (docs/auth.md, "Sign-up"): required with SMS off,
      // optional with SMS on, and not sent when left empty. The pool
      // auto-verifies it, so Cognito emails a code either at signup (SMS
      // off - email is the only channel) or via the post-login VerifyEmail
      // gate (SMS on - the signup code goes to the phone).
      email: state.email,
      // Phone number is only collected when the pool is wired for SMS
      // (a 10DLC campaign registration id is configured). See issue #712
      // and terraform/infra/modules/user_pool/main.tf.
      phone: state.sms_enabled ? state.phone : null,
      // Shared-secret invitation code, validated by the check_invite
      // Cognito pre-signup Lambda. The client sends it as validation
      // data so it never lands on the user record.
      invitationCode: state.inviteCode,
    }).then(({ codeDelivery }) => {
      // Let Cognito say where the confirmation code went rather than
      // assuming. No delivery details means no code was sent at all:
      // with SMS off, the check_invite pre-signup trigger auto-confirms
      // the account (issue #712), so there is nothing to verify here -
      // email verification happens at first sign-in instead.
      if (!codeDelivery) {
        setState({ view: "Login", inviteCode: null });
        setMessage(
          "Account created. It is pending admin approval; you'll be notified when it is ready.",
          false
        );
        return;
      }
      setSignupDelivery(codeDelivery);
      setState({ view: "Verify", inviteCode: null });
      setMessage(`Check your ${codeDelivery.medium} for a verification code.`, false);
    }, (err) => {
      setState({ view: "SignUp" });
      setMessage(signUpErrorMessage(err), true);
    });
  }, [state.userName, state.password, state.email, state.phone, state.inviteCode, state.sms_enabled, requireAuth, setState, setMessage]);

  const doVerify = useCallback((e) => {
    e.preventDefault();
    const auth = requireAuth();
    if (!auth) return;
    auth.client.confirmSignUp(state.userName, state.verificationCode).then(() => {
      signupResend.reset();
      const which = signupDelivery && signupDelivery.medium === 'email' ? 'Email' : 'Phone';
      setState({ view: "Login", verificationCode: null });
      setMessage(`${which} verified. Your account is pending admin approval.`, false);
    }, () => {
      setMessage("Verification failed. Please check your code and try again.", true);
    });
  }, [state.userName, state.verificationCode, signupDelivery, requireAuth, setState, setMessage, signupResend]);

  const doResendVerification = useCallback(() => {
    if (signupResend.locked || signupResendInFlight || !state.userName) return;
    const auth = requireAuth();
    if (!auth) return;
    setSignupResendInFlight(true);
    auth.client.resendConfirmationCode(state.userName).then((delivery) => {
      setSignupResendInFlight(false);
      const medium = (delivery && delivery.medium) || 'phone';
      setMessage(`A new verification code has been sent to your ${medium}.`, false);
    }, (err) => {
      setSignupResendInFlight(false);
      // Cognito hit its per-user resend limit. Mirror the lockout in
      // local state so the UI stops offering Resend until the window
      // passes; the message echoes Cognito rather than inventing a
      // schedule.
      if (isLimitExceeded(err)) {
        signupResend.recordLimitHit();
        setMessage("Too many resend attempts. Please try again later.", true);
      } else {
        setMessage("Could not resend code. Please try again later.", true);
      }
    });
  }, [state.userName, signupResend, signupResendInFlight, requireAuth, setMessage]);

  const doForgotPassword = useCallback((e) => {
    e.preventDefault();
    const auth = requireAuth();
    if (!auth) return;
    // Recovery is email-first now (identity plan Phase 1); read where
    // Cognito actually sent the code instead of hardcoding "phone".
    auth.client.forgotPassword(state.userName).then((delivery) => {
      const medium = (delivery && delivery.medium) || 'phone';
      setForgotDelivery(medium);
      setForgotPasswordSent(true);
      setMessage(`A reset code has been sent to your ${medium}.`, false);
    }, () => {
      setMessage("Failed to send reset code. Please try again.", true);
    });
  }, [state.userName, requireAuth, setMessage]);

  const doResendResetCode = useCallback(() => {
    if (resetResend.locked || resetResendInFlight || !state.userName) return;
    const auth = requireAuth();
    if (!auth) return;
    setResetResendInFlight(true);
    auth.client.forgotPassword(state.userName).then((delivery) => {
      const medium = (delivery && delivery.medium) || 'phone';
      setForgotDelivery(medium);
      setResetResendInFlight(false);
      setMessage(`A new reset code has been sent to your ${medium}.`, false);
    }, (err) => {
      setResetResendInFlight(false);
      if (isLimitExceeded(err)) {
        resetResend.recordLimitHit();
        setMessage("Too many resend attempts. Please try again later.", true);
      } else {
        setMessage("Could not resend code. Please try again later.", true);
      }
    });
  }, [state.userName, resetResend, resetResendInFlight, requireAuth, setMessage]);

  const doResetPassword = useCallback((e) => {
    e.preventDefault();
    const auth = requireAuth();
    if (!auth) return;
    auth.client.confirmForgotPassword(state.userName, state.verificationCode, state.password).then(() => {
      resetResend.reset();
      setState({ view: "Login", verificationCode: null, password: null });
      setMessage("Password reset successful. You can now log in.", false);
    }, () => {
      setMessage("Password reset failed. Please check your code and try again.", true);
    });
  }, [state.userName, state.verificationCode, state.password, requireAuth, setState, setMessage, resetResend]);

  // Run a callback with the signed-in user's access token, refreshed
  // first if it is close to expiring. The user-attribute and MFA
  // operations authenticate with it.
  const withAccessToken = useCallback((fn, onUnavailable) => {
    const auth = authRef.current;
    if (!auth) {
      if (onUnavailable) onUnavailable();
      return;
    }
    auth.session.accessToken().then(
      (accessToken) => fn(auth.client, accessToken),
      () => { if (onUnavailable) onUnavailable(); }
    );
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
  const finishLogin = useCallback((tokens, username, mfaVerified = false) => {
    // A login does not always follow an explicit logout (session expiry
    // lands on the login form directly), so stale cached lists from a
    // previous account must be dropped here, not just in doLogout.
    clearListCaches();
    const auth = authRef.current;
    auth.session.establish(tokens, decodeJwtPayload(tokens.idToken)['cognito:username'] || username);
    pendingMfaRef.current = null;
    // One GetUser answers both gates: the attributes and the MFA list.
    auth.client.getUser(tokens.accessToken).then((user) => {
      let next = { loggedIn: true, view: "Email" };
      const { email, email_verified: emailVerified } = user.attributes;
      // With SMS on, a verified phone already recovers the account, so an
      // account without an email is not asked to add one; one that gave an
      // email is still asked to verify it (docs/auth.md, "After sign-in").
      const phoneRecovers = state.sms_enabled
        && user.attributes.phone_number_verified === 'true';
      if (!email && !phoneRecovers) {
        setEmailGate({ mode: 'add', address: null });
        next = { loggedIn: true, view: "VerifyEmail", email: null };
      } else if (email && emailVerified !== 'true') {
        setEmailGate({ mode: 'verify', address: email });
        next = { loggedIn: true, view: "VerifyEmail", verificationCode: null };
      } else if (!mfaVerified && !user.mfaSettings.includes('SOFTWARE_TOKEN_MFA')) {
        next = { loggedIn: true, view: "EnrollMfa" };
      }
      setState(next);
      setMessage("Login succeeded", false);
    }, () => {
      // Fail open: nudging is not worth blocking a login over.
      setState({ loggedIn: true, view: "Email" });
      setMessage("Login succeeded", false);
    });
  }, [state.sms_enabled, setState, setMessage]);

  const doLogin = useCallback((e) => {
    e.preventDefault();
    const auth = requireAuth();
    if (!auth) return;
    const username = state.userName;
    auth.client.signIn(username, state.password).then((result) => {
      if (result.status === 'mfa') {
        // Second-factor challenge (identity plan Phase 1). The challenge
        // waits in a ref until the MfaChallenge screen submits the code.
        pendingMfaRef.current = result.challenge;
        setMfaChallengeType(result.mfa);
        setState({ view: "MfaChallenge", verificationCode: null });
        return;
      }
      finishLogin(result.tokens, username);
    }, (err) => {
      auth.session.clear();
      // The require_admin_mfa pre-token-generation trigger (enforce
      // mode) rejects any un-enrolled account. Route to the
      // self-service setup flow (#768) when the enrollment client is
      // configured; otherwise surface an actionable banner.
      const mfaBlocked = isMfaEnrollmentRequired(err);
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
    });
  }, [state.userName, state.password, state.enroll_client_id, requireAuth, finishLogin, setState, setMessage]);

  const doSubmitMfaCode = useCallback((e) => {
    e.preventDefault();
    const challenge = pendingMfaRef.current;
    if (!challenge) {
      // The challenge lives only in memory; a reload mid-challenge
      // loses it and the login must restart.
      setState({ view: "Login", verificationCode: null });
      setMessage("Your sign-in session expired. Please log in again.", true);
      return;
    }
    const auth = requireAuth();
    if (!auth) return;
    auth.client.respondToMfaChallenge(challenge, state.verificationCode).then((result) => {
      if (result.status !== 'signed-in') {
        // A second challenge after the first: nothing this pool asks.
        pendingMfaRef.current = null;
        setState({ view: "Login", verificationCode: null });
        setMessage("Login failed", true);
        return;
      }
      finishLogin(result.tokens, challenge.username, true);
    }, (err) => {
      // Cognito keeps a challenge answerable for a few minutes and a few
      // wrong codes; past either it refuses the session itself, and the
      // sign-in has to start over.
      if (isNotAuthorized(err)) {
        pendingMfaRef.current = null;
        setState({ view: "Login", verificationCode: null });
        setMessage("Your sign-in session expired. Please log in again.", true);
        return;
      }
      setMessage("That code did not match. Please try again.", true);
    });
  }, [state.verificationCode, requireAuth, finishLogin, setState, setMessage]);

  // --- Locked-out TOTP setup handlers (#768) ---
  //
  // The gate rejects password logins for un-enrolled accounts, so the
  // normal client can never yield a session to enroll with. These
  // re-authenticate through the dedicated enrollment app client
  // (enrollClientId from /config.js), which the gate passes for
  // factorless users only, then run the same associate/verify/prefer
  // sequence as the Security view with that client's short-lived access
  // token. The token stays in memory and is never part of the session.

  const beginMfaSetup = useCallback(() => {
    const auth = authRef.current;
    if (!auth || !auth.enrollClient || !state.userName || !state.password) {
      // The password never survives a reload (persistState strips it),
      // so a revisit of this view has to restart from Login.
      setState({ view: "Login" });
      setMessage("Please enter your password again to continue.", true);
      return;
    }
    const { enrollClient } = auth;
    const failed = () => {
      setMfaSetupBusy(false);
      setMessage("Could not start two-factor setup. Please try again.", true);
    };
    setMfaSetupBusy(true);
    enrollClient.signIn(state.userName, state.password).then((result) => {
      if (result.status !== 'signed-in') {
        // Only an already-enrolled account draws a second-factor
        // challenge here; normal sign-in is the right path for it.
        setMfaSetupBusy(false);
        setState({ view: "Login" });
        setMessage("This account already has an authenticator. Sign in normally.", true);
        return;
      }
      const { accessToken } = result.tokens;
      enrollClient.associateSoftwareToken(accessToken).then((secret) => {
        setMfaSetupBusy(false);
        mfaSetupRef.current = { accessToken };
        setMfaSetupSecret(secret);
        setState({ verificationCode: null });
      }, failed);
    }, failed);
  }, [state.userName, state.password, setState, setMessage]);

  const doConfirmMfaSetup = useCallback((e) => {
    e.preventDefault();
    const setup = mfaSetupRef.current;
    const auth = authRef.current;
    if (!setup || !auth || !auth.enrollClient) {
      // The enrollment token lives only in memory; a reload mid-setup
      // loses it and the flow must restart.
      setMfaSetupSecret(null);
      setState({ view: "Login", verificationCode: null });
      setMessage("Your setup session expired. Please log in again.", true);
      return;
    }
    const { enrollClient } = auth;
    setMfaSetupBusy(true);
    enrollClient.verifySoftwareToken(setup.accessToken, state.verificationCode, 'Cabalmail').then(() => {
      enrollClient.setSoftwareTokenMfa(setup.accessToken, true).then(() => {
        setMfaSetupBusy(false);
        // Drop the enrollment token; the normal sign-in (which now
        // issues a TOTP challenge) is what counts.
        mfaSetupRef.current = null;
        setMfaSetupSecret(null);
        setState({ view: "Login", verificationCode: null });
        setMessage("Two-factor authentication is on. Sign in again with a code from your app.", false);
      }, () => {
        setMfaSetupBusy(false);
        setMessage("Could not turn on two-factor authentication. Please try again.", true);
      });
    }, () => {
      setMfaSetupBusy(false);
      setMessage("That code did not match. Check your authenticator app and try again.", true);
    });
  }, [state.verificationCode, setState, setMessage]);

  const cancelMfaSetup = useCallback((e) => {
    e.preventDefault();
    mfaSetupRef.current = null;
    setMfaSetupSecret(null);
    setMfaSetupBusy(false);
    setState({ view: "Login", verificationCode: null });
  }, [setState]);

  // --- VerifyEmail gate handlers (identity plan Phase 1) ---

  // "add" mode: save the address. The pool auto-verifies email, so
  // UpdateUserAttributes makes Cognito send the verification code itself.
  const doSaveRecoveryEmail = useCallback((e) => {
    e.preventDefault();
    const address = state.email;
    if (!address) return;
    withAccessToken((client, accessToken) => {
      client.updateUserAttributes(accessToken, { email: address }).then(() => {
        setEmailGate({ mode: 'verify', address });
        setState({ verificationCode: null });
        setMessage(`A verification code has been sent to ${address}.`, false);
      }, () => {
        setMessage("Could not save that address. Please try again.", true);
      });
    }, () => setMessage("Your session expired. Please log in again.", true));
  }, [state.email, withAccessToken, setState, setMessage]);

  const doSendEmailCode = useCallback(() => {
    if (emailSendInFlight) return;
    setEmailSendInFlight(true);
    withAccessToken((client, accessToken) => {
      client.getUserAttributeVerificationCode(accessToken, 'email').then(() => {
        setEmailSendInFlight(false);
        setMessage("A verification code has been sent to your email.", false);
      }, (err) => {
        setEmailSendInFlight(false);
        setMessage(
          isLimitExceeded(err)
            ? "Too many attempts. Please try again later."
            : "Could not send a code. Please try again later.",
          true
        );
      });
    }, () => {
      setEmailSendInFlight(false);
      setMessage("Your session expired. Please log in again.", true);
    });
  }, [emailSendInFlight, withAccessToken, setMessage]);

  const doVerifyEmailCode = useCallback((e) => {
    e.preventDefault();
    withAccessToken((client, accessToken) => {
      client.verifyUserAttribute(accessToken, 'email', state.verificationCode).then(() => {
        setEmailGate(null);
        setState({ view: "Email", verificationCode: null });
        setMessage("Email verified. It can now be used for account recovery.", false);
      }, () => {
        setMessage("Verification failed. Please check your code and try again.", true);
      });
    }, () => setMessage("Your session expired. Please log in again.", true));
  }, [state.verificationCode, withAccessToken, setState, setMessage]);

  const skipEmailGate = useCallback((e) => {
    e.preventDefault();
    setEmailGate(null);
    setState({ view: "Email" });
  }, [setState]);

  // TOTP enrollment surface for the Security view. Thin wrappers so the
  // Cognito calls stay in App (where the client and session live) and the
  // view can be tested with a mock.
  const mfaApi = useMemo(() => ({
    getStatus: (cb) => withAccessToken(
      (client, accessToken) => client.getUser(accessToken).then(
        (user) => cb(null, user.mfaSettings.includes('SOFTWARE_TOKEN_MFA')),
        (err) => cb(err)
      ),
      () => cb(new Error('no session'))
    ),
    beginEnroll: (callbacks) => withAccessToken(
      (client, accessToken) => client.associateSoftwareToken(accessToken).then(
        (secret) => callbacks.associateSecretCode(secret),
        callbacks.onFailure
      ),
      () => callbacks.onFailure(new Error('no session'))
    ),
    confirmEnroll: (code, callbacks) => withAccessToken(
      (client, accessToken) => client.verifySoftwareToken(accessToken, code, 'Cabalmail')
        .then(() => client.setSoftwareTokenMfa(accessToken, true))
        .then(() => callbacks.onSuccess(), callbacks.onFailure),
      () => callbacks.onFailure(new Error('no session'))
    ),
    disable: (cb) => withAccessToken(
      (client, accessToken) => client.setSoftwareTokenMfa(accessToken, false).then(() => cb(null), cb),
      () => cb(new Error('no session'))
    ),
  }), [withAccessToken]);

  const doLogout = useCallback((e) => {
    e.preventDefault();
    if (authRef.current) authRef.current.session.clear();
    clearListCaches();
    pendingMfaRef.current = null;
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
    if (restoring) {
      return <div className="loading">Loading...</div>;
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
        // The gate is memory-only and a reload starts from a logged-out
        // view (loadSavedState), so this can't be reached without one;
        // render nothing rather than a gate with no context.
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
              token={token}
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
    token,
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

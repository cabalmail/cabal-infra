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
const About = React.lazy(() => import('./About'));

// Pre-login Components
import SignUp from './SignUp';
import Login from './Login';
import Verify from './Verify';
import ForgotPassword from './ForgotPassword';
import ResetPassword from './ResetPassword';

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
import useKeyboardShortcuts from './hooks/useKeyboardShortcuts';

// Site-wide and Theme-specific style.
// AppLight.css defines unconditional default tokens; AppDark.css overrides
// them inside @media (prefers-color-scheme: dark). Load light first so the
// media-gated dark rules win by source order at equal specificity.
import './AppLight.css';
import './AppDark.css';
import { ADDRESS_LIST, FOLDER_LIST, DATE, DESC } from './constants';
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
    phone: null,
    verificationCode: null,
    view: "Login",
    poolData: null,
    control_domain: null,
    imap_host: null,
    domains: {},
    api_url: null,
  };
  const saved = JSON.parse(window.localStorage.getItem('state'));
  return saved ? { ...defaults, ...saved, password: null } : defaults;
}

function persistState(state) {
  try {
    const { password, ...safe } = state;
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

  // Phase 7 §3: controls the ForgotPassword success state. Set on Cognito
  // `forgotPassword` success; cleared when the user leaves the screen.
  const [forgotPasswordSent, setForgotPasswordSent] = useState(false);

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
      // About is reachable when logged out via the auth-shell footer link,
      // so it must not be bounced back to Login here.
      const allowedWhenLoggedOut = [
        "Login", "SignUp", "Verify", "ForgotPassword", "ResetPassword", "About"
      ];
      if (!allowedWhenLoggedOut.includes(prev.view)) {
        updates.view = "Login";
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

  // Fetch config and restore session on mount
  useEffect(() => {
    axios.get('/config.js').then(({ data }) => {
      const { control_domain, domains, cognitoConfig } = data;
      UserPool = new CognitoUserPool(cognitoConfig.poolData);
      setState({
        poolData: cognitoConfig.poolData,
        control_domain,
        imap_host: control_domain.match(/^dev\./)
          ? control_domain.replace("dev.", "imap.")
          : "imap." + control_domain,
        domains,
        api_url: "https://admin." + control_domain + "/prod"
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
    const adminOnlyViews = ["Addresses", "Users", "DMARC"];
    if (state.loggedIn && !isAdmin && adminOnlyViews.includes(state.view)) {
      setState({ view: "Email" });
    }
  }, [state.loggedIn, state.view, isAdmin, setState]);

  const doRegister = useCallback((e) => {
    e.preventDefault();
    const attributeUsername = new CognitoUserAttribute({
      Name: 'preferred_username',
      Value: state.userName
    });
    const attributePhone = new CognitoUserAttribute({
      Name: 'phone_number',
      Value: state.phone
    });
    UserPool.signUp(
      state.userName,
      state.password,
      [attributeUsername, attributePhone],
      null,
      (err, _result) => {
        if (!err) {
          setState({ view: "Verify" });
          setMessage("Check your phone for a verification code.", false);
        } else {
          setState({ view: "SignUp" });
          setMessage("Registration failed.", true);
        }
      }
    );
  }, [state.userName, state.password, state.phone, setState, setMessage]);

  const doVerify = useCallback((e) => {
    e.preventDefault();
    const cognitoUser = new CognitoUser({
      Username: state.userName,
      Pool: UserPool
    });
    cognitoUser.confirmRegistration(state.verificationCode, true, (err, _result) => {
      if (!err) {
        setState({ view: "Login", verificationCode: null });
        setMessage("Phone verified. Your account is pending admin approval.", false);
      } else {
        setMessage("Verification failed. Please check your code and try again.", true);
      }
    });
  }, [state.userName, state.verificationCode, setState, setMessage]);

  const doForgotPassword = useCallback((e) => {
    e.preventDefault();
    const cognitoUser = new CognitoUser({
      Username: state.userName,
      Pool: UserPool
    });
    cognitoUser.forgotPassword({
      onSuccess: () => {
        setForgotPasswordSent(true);
        setMessage("A reset code has been sent to your phone.", false);
      },
      onFailure: () => {
        setMessage("Failed to send reset code. Please try again.", true);
      },
      inputVerificationCode: () => {
        setForgotPasswordSent(true);
        setMessage("A reset code has been sent to your phone.", false);
      }
    });
  }, [state.userName, setMessage]);

  const doResetPassword = useCallback((e) => {
    e.preventDefault();
    const cognitoUser = new CognitoUser({
      Username: state.userName,
      Pool: UserPool
    });
    cognitoUser.confirmPassword(state.verificationCode, state.password, {
      onSuccess: () => {
        setState({ view: "Login", verificationCode: null, password: null });
        setMessage("Password reset successful. You can now log in.", false);
      },
      onFailure: () => {
        setMessage("Password reset failed. Please check your code and try again.", true);
      }
    });
  }, [state.userName, state.verificationCode, state.password, setState, setMessage]);

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
      onSuccess: data => {
        _token = data.getIdToken().getJwtToken();
        _expires = data.getIdToken().getExpiration();
        const payload = JSON.parse(atob(_token.split('.')[1]));
        const groups = payload['cognito:groups'] || [];
        setIsAdmin(groups.includes('admin'));
        setState({ loggedIn: true, view: "Email" });
        setMessage("Login succeeded", false);
      },
      onFailure: () => {
        _token = null;
        _expires = Math.floor(new Date() / 1000) - 1;
        setState({ loggedIn: false, view: "Login" });
        setMessage("Login failed", true);
      }
    });
  }, [state.userName, state.password, setState, setMessage]);

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
    localStorage.removeItem("INBOX");
    setIsAdmin(false);
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

  function renderContent() {
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
            <Users />
          </ErrorBoundary>
        );
      case "DMARC":
        return (
          <ErrorBoundary name="DMARC">
            <Dmarc />
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
          />
        );
      case "ForgotPassword":
        return (
          <ForgotPassword
            onSubmit={doForgotPassword}
            onUsernameChange={doInputChange}
            username={state.userName}
            submitted={forgotPasswordSent}
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
          />
        );
      case "SignUp":
        return (
          <SignUp
            onSubmit={doRegister}
            onUsernameChange={doInputChange}
            onPhoneChange={doInputChange}
            onPasswordChange={doInputChange}
            username={state.userName}
            password={state.password}
            phone={state.phone}
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
    domains: state.domains
  };

  const isPreLoginView = ["Login", "SignUp", "Verify", "ForgotPassword", "ResetPassword"]
    .includes(state.view);

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

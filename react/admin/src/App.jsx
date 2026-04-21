// Third party libs

import React, { useState, useEffect, useCallback, useRef, Suspense } from 'react';
import axios from 'axios';
import {
  CognitoUser,
  CognitoUserPool,
  CognitoUserAttribute,
  AuthenticationDetails
} from 'amazon-cognito-identity-js';

// Lazy-loaded view components
const Email = React.lazy(() => import('./Email'));
const Folders = React.lazy(() => import('./Folders'));
const Addresses = React.lazy(() => import('./Addresses'));
const Users = React.lazy(() => import('./Users'));
const Dmarc = React.lazy(() => import('./Dmarc'));

// Pre-login Components
import SignUp from './SignUp';
import Login from './Login';
import Verify from './Verify';
import ForgotPassword from './ForgotPassword';
import ResetPassword from './ResetPassword';

// Persistent Components
import AppMessage from './AppMessage';
import Nav from './Nav';

// Error Boundary
import ErrorBoundary from './ErrorBoundary';

// Contexts
import AuthContext from './contexts/AuthContext';
import AppMessageContext from './contexts/AppMessageContext';

// Hooks
import useTheme from './hooks/useTheme';

// Site-wide and Theme-specific style
import './AppDark.css';
import './AppLight.css';
import { ADDRESS_LIST, FOLDER_LIST } from './constants';
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
  const theme = useTheme();

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
      const preLoginViews = ["Login", "SignUp", "Verify", "ForgotPassword", "ResetPassword"];
      if (!preLoginViews.includes(prev.view)) {
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
        setState({ view: "ResetPassword" });
        setMessage("A reset code has been sent to your phone.", false);
      },
      onFailure: () => {
        setMessage("Failed to send reset code. Please try again.", true);
      },
      inputVerificationCode: () => {
        setState({ view: "ResetPassword" });
        setMessage("A reset code has been sent to your phone.", false);
      }
    });
  }, [state.userName, setState, setMessage]);

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
              token={_token}
              api_url={state.api_url}
              host={state.imap_host}
              domains={state.domains}
              setMessage={setMessage}
              isAdmin={isAdmin}
            />
          </ErrorBoundary>
        );
      case "Folders":
        return (
          <ErrorBoundary name="Folders">
            <Folders
              token={_token}
              api_url={state.api_url}
              host={state.imap_host}
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
          />
        );
      case "ForgotPassword":
        return (
          <ForgotPassword
            onSubmit={doForgotPassword}
            onUsernameChange={doInputChange}
            username={state.userName}
            onCancel={(e) => { e.preventDefault(); setState({ view: "Login" }); }}
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
            onForgotPassword={(e) => { e.preventDefault(); setState({ view: "ForgotPassword" }); }}
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

  return (
    <AuthContext.Provider value={authValue}>
      <AppMessageContext.Provider value={{ setMessage }}>
        <div className={`App ${state.view}`}>
          <Nav
            onClick={updateView}
            loggedIn={state.loggedIn}
            view={state.view}
            doLogout={doLogout}
            isAdmin={isAdmin}
            userName={state.userName}
            theme={theme.theme}
            accent={theme.accent}
            onToggleTheme={theme.toggleTheme}
            onSelectAccent={theme.setAccent}
            accents={theme.accents}
          />
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
        </div>
      </AppMessageContext.Provider>
    </AuthContext.Provider>
  );
}

export default App;

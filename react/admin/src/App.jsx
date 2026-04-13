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

// Persistent Components
import AppMessage from './AppMessage';
import Nav from './Nav';

// Error Boundary
import ErrorBoundary from './ErrorBoundary';

// Contexts
import AuthContext from './contexts/AuthContext';
import AppMessageContext from './contexts/AppMessageContext';

// Site-wide and Theme-specific style
import './AppDark.css';
import './AppLight.css';
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
      if (prev.view !== "Login" && prev.view !== "SignUp") {
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
          setState({ view: "Login" });
          setMessage("Your registration has been submitted.", false);
        } else {
          setState({ view: "SignUp" });
          setMessage("Registration failed.", true);
        }
      }
    );
  }, [state.userName, state.password, state.phone, setState, setMessage]);

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
      case "SignUp":
        return (
          <SignUp
            onSubmit={doRegister}
            onUsernameChange={doInputChange}
            onPasswordChange={doInputChange}
            onPhoneChange={doInputChange}
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

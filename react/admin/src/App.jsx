// Third party libs

import React, { Suspense } from 'react';
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

/**
 * Application for reading Cabalmail email and
 * managing Cabalmail addresses and folders
 */

class App extends React.Component {

  constructor(props) {
    super(props);
    const defaults = {
      loggedIn: false,
      userName: null,
      password: null,
      phone: null,
      message: null,
      error: false,
      view: "Login",
      poolData: null,
      control_domain: null,
      imap_host: null,
      domains: {},
      api_url: null,
      hideMessage: true
    };
    const saved = JSON.parse(window.localStorage.getItem('state'));
    this.state = saved
      ? { ...defaults, ...saved, password: null }
      : defaults;
  }

  persistState(state) {
    const { password, ...safe } = { ...this.state, ...state };
    try {
      window.localStorage.setItem('state', JSON.stringify(safe));
    } catch (e) {
      console.log(e);
    }
  }

  setState(state) {
    this.persistState(state);
    super.setState(state);
  }

  componentWillUnmount() {
    window.removeEventListener("focus", this.checkSession);
  }

  componentDidMount() {
    const response = this.getConfig();
    response.then(data => {
      const { control_domain, domains, cognitoConfig } = data.data;
      UserPool = new CognitoUserPool(cognitoConfig.poolData);
      this.setState({
        ...this.state,
        poolData: cognitoConfig.poolData,
        control_domain: control_domain,
        imap_host: control_domain.match(/^dev\./) ? control_domain.replace("dev.", "imap.") : "imap." + control_domain,
        domains: domains,
        api_url: "https://admin." + control_domain + "/prod"
      });
      this.refreshSession();
    });
    window.addEventListener("focus", this.checkSession);
  }

  componentDidUpdate(prevProps, prevState) {
    this.checkSession();
  }

  refreshSession = () => {
    if (!UserPool) return;
    const cognitoUser = UserPool.getCurrentUser();
    if (!cognitoUser) return;
    cognitoUser.getSession((err, session) => {
      if (err || !session || !session.isValid()) return;
      _token = session.getIdToken().getJwtToken();
      _expires = session.getIdToken().getExpiration();
      this.setState({
        ...this.state,
        loggedIn: true,
        view: "Email"
      });
    });
  }

  checkSession = () => {
    if (_expires < Math.floor(Date.now() / 1000)) {
      if (this.state.view !== "Login" && this.state.view !== "SignUp") {
        this.setState({
          ...this.state,
          view: "Login"
        });
      }
      if (_token !== null) {
        _token = null;
      }
      if (this.state.loggedIn !== false) {
        this.setState({
          ...this.state,
          loggedIn: false
        })
      }
    }
  }

  setMessage = (m, e) => {
    var message = m;
    var error = e;
    const timeout = error ? 15000 : 4000;
    this.checkSession()
    this.setState({...this.state, message: message, error: error, hideMessage: false});
    setTimeout(() => {
      this.setState({...this.state, hideMessage: true});
    }, timeout);
  }

  getConfig = () => {
    const response = axios.get('/config.js');
    return response;
  }

  doRegister = e => {
    e.preventDefault();
    const dataUsername = {
      Name: 'preferred_username',
      Value: this.state.userName
    };
    const dataPhone = {
      Name: 'phone_number',
      Value: this.state.phone
    };
    const attributeUsername = new CognitoUserAttribute(dataUsername);
    const attributePhone = new CognitoUserAttribute(dataPhone);
    UserPool.signUp(
      this.state.userName,
      this.state.password,
      [attributeUsername, attributePhone],
      null,
      (err, _result) => {
        if (!err) {
          this.setState({
            ...this.state,
            view: "Login"
          });
          this.setMessage("Your registration has been submitted.", false);
        } else {
          this.setState({
            ...this.state,
            view: "SignUp"
          });
          this.setMessage("Registration failed.", true);
        }
      }
    );
  }

  doLogin = e => {
    e.preventDefault();
    const user = new CognitoUser({
      Username: this.state.userName,
      Pool: UserPool
    });
    const creds = new AuthenticationDetails({
      Username: this.state.userName,
      Password: this.state.password
    });
    user.authenticateUser(creds, {
      onSuccess: data => {
        _token = data.getIdToken().getJwtToken();
        _expires = data.getIdToken().getExpiration();
        this.setState({
          ...this.state,
          message: "",
          loggedIn: true,
          view: "Email"
        });
        this.setMessage("Login succeeded", false);
      },
      onFailure: data => {
        _token = null;
        _expires = Math.floor(new Date() / 1000) - 1;
        this.setState({
          ...this.state,
          loggedIn: false,
          view: "Login"
        });
        this.setMessage("Login failed", true);
      }
    });
  }

  doLogout = (e) => {
    e.preventDefault();
    _token = null;
    _expires = Math.floor(new Date() / 1000) - 1;
    if (UserPool) {
      const cognitoUser = UserPool.getCurrentUser();
      if (cognitoUser) cognitoUser.signOut();
    }
    this.setState({
      ...this.state,
      loggedIn: false,
      userName: null,
      password: null,
      view: "Login"
    });
  }

  doInputChange = e => {
    e.preventDefault();
    this.setState({...this.state, [e.target.name]: e.target.value});
  }

  updateView = e => {
    e.preventDefault();
    this.setState({...this.state, view: e.target.name});
  }

  renderContent() {
    switch (this.state.view) {
      case "Addresses":
        return (
          <ErrorBoundary name="Addresses">
            <Addresses
              token={_token}
              api_url={this.state.api_url}
              host={this.state.imap_host}
              domains={this.state.domains}
              setMessage={this.setMessage}
            />
          </ErrorBoundary>
        );
      case "Folders":
        return (
          <ErrorBoundary name="Folders">
            <Folders
              token={_token}
              api_url={this.state.api_url}
              host={this.state.imap_host}
              setMessage={this.setMessage}
            />
          </ErrorBoundary>
        );
      case "SignUp":
        return (
          <SignUp
            onSubmit={this.doRegister}
            onUsernameChange={this.doInputChange}
            onPasswordChange={this.doInputChange}
            onPhoneChange={this.doInputChange}
          />
        );
      case "Email":
        return (
          <ErrorBoundary name="Email">
            <Email
              token={_token}
              api_url={this.state.api_url}
              host={this.state.imap_host}
              smtp_host={`smtp-out.${this.state.control_domain}`}
              domains={this.state.domains}
              setMessage={this.setMessage}
            />
          </ErrorBoundary>
        );
      case "Logout":
        return (
          <Login
            onSubmit={this.doLogin}
            onUsernameChange={this.doInputChange}
            onPasswordChange={this.doInputChange}
            username={this.state.userName}
            password={this.state.password}
          />
        );
      case "Login":
      default:
        return (
          <Login
            onSubmit={this.doLogin}
            onUsernameChange={this.doInputChange}
            onPasswordChange={this.doInputChange}
            username={this.state.userName}
            password={this.state.password}
          />
        );
    };
  }

  render() {
    const authValue = {
      token: _token,
      api_url: this.state.api_url,
      host: this.state.imap_host,
      smtp_host: `smtp-out.${this.state.control_domain}`,
      domains: this.state.domains
    };
    const appMessageValue = { setMessage: this.setMessage };
    return (
      <AuthContext.Provider value={authValue}>
        <AppMessageContext.Provider value={appMessageValue}>
          <div className={`App ${this.state.view}`}>
            <Nav
              onClick={this.updateView}
              loggedIn={this.state.loggedIn}
              view={this.state.view}
              doLogout={this.doLogout}
            />
            <div className="content">
              <Suspense fallback={<div className="loading">Loading...</div>}>
                {this.renderContent()}
              </Suspense>
            </div>
            <AppMessage
              message={this.state.message}
              hide={this.state.hideMessage}
              error={this.state.error}
            />
          </div>
        </AppMessageContext.Provider>
      </AuthContext.Provider>
    );
  }

}

export default App;

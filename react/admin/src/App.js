import React from 'react';
import axios from 'axios';
import {
  CognitoUser,
  CognitoUserPool,
  CognitoUserAttribute,
  AuthenticationDetails
} from 'amazon-cognito-identity-js';
import Addresses from './Addresses';
import SignUp from './SignUp';
import Login from './Login';
import AppMessage from './AppMessage';
import Nav from './Nav';
import Email from './Email';
import Folders from './Folders';
import './App.css';
let UserPool = null;

/**
 * Application for managing Cabalmail addresses via web user interface
 */

class App extends React.Component {

  constructor(props) {
    super(props);
    this.state = JSON.parse(window.localStorage.getItem('state')) || {
      loggedIn: false,
      token: null,
      expires: Math.floor(new Date() / 1000) - 1,
      userName: null,
      password: null,
      phone: null,
      message: null,
      error: false,
      view: "Login",
      poolData: null,
      control_domain: null,
      domains: {},
      api_url: null,
      hideMessage: true
    };
  }

  setState(state) {
    window.localStorage.setItem('state', JSON.stringify(state));
    super.setState(state);
  }

  componentDidMount() {
    const response = this.getConfig();
    response.then(data => {
      const { control_domain, domains, cognitoConfig } = data.data;
      this.setState({
        ...this.state,
        poolData: cognitoConfig.poolData,
        control_domain: control_domain,
        domains: domains,
        api_url: "https://admin." + control_domain + "/prod"
      });
      UserPool = new CognitoUserPool(cognitoConfig.poolData);
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if (this.state.expires < Math.floor(Date.now() / 1000)) {
      if (this.state.view !== "Login" && this.state.view !== "SignUp") {
        this.setState({
          ...this.state,
          view: "Login"
        });
      }
      if (this.state.token !== null) {
        this.setState({
          ...this.state,
          token: null
        })
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
    if (this.state.expires < Math.floor(new Date() / 1000) && this.state.loggedIn) {
      this.setState({...this.state, view: "Login", loggedIn: false});
      message = "Session expired";
      error = true;
    }
    this.setState({...this.state, message: message, error: error, hideMessage: false});
    setTimeout(() => {
      this.setState({...this.state, hideMessage: true});
    }, 15000);
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
        this.setState({
          ...this.state,
          message: "",
          loggedIn: true,
          token: data.getIdToken().getJwtToken(),
          expires: data.getIdToken().getExpiration(),
          view: "Email"
        });
      },
      onFailure: data => {
        this.setState({
          ...this.state,
          loggedIn: false,
          token: null,
          expires: Math.floor(new Date() / 1000) - 1,
          view: "Login"
        });
        this.setMessage("Login failed", true);
      }
    });
  }

  doLogout = (e) => {
    e.preventDefault();
    this.setState({
      ...this.state,
      loggedIn: false,
      token: null,
      expires: Math.floor(new Date() / 1000) - 1,
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
          <Addresses
            token={this.state.token}
            api_url={this.state.api_url}
            domains={this.state.domains}
            setMessage={this.setMessage}
          />
        );
      case "Folders":
        return (
          <Folders
            token={this.state.token}
            api_url={this.state.api_url}
            host={`imap.${this.state.control_domain}`}
            setMessage={this.setMessage}
          />
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
          <Email
            token={this.state.token}
            api_url={this.state.api_url}
            host={`imap.${this.state.control_domain}`}
            setMessage={this.setMessage}
          />
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
    return (
      <div className={`App ${this.state.view}`}>
        <Nav
          onClick={this.updateView}
          loggedIn={this.state.loggedIn}
          view={this.state.view}
          doLogout={this.doLogout}
        />
        <AppMessage
          message={this.state.message}
          hide={this.state.hideMessage}
          error={this.state.error}
        />
        <div className="content">
          {this.renderContent()}
        </div>
      </div>
    );
  }

}

export default App;
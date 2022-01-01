import React from 'react';
import axios from 'axios';
import {
  CognitoUser,
  CognitoUserPool,
  CognitoUserAttribute,
  AuthenticationDetails
} from 'amazon-cognito-identity-js';
import Request from './Request';
import List from './List';
import SignUp from './SignUp';
import Login from './Login';
import Message from './Message';
import Nav from './Nav';
let UserPool = null;

class App extends React.Component {

  constructor(props) {
    super(props);
    this.state = JSON.parse(window.localStorage.getItem('state')) || {
      loggedIn: false,
      token: null,
      expires: new Date(),
      userName: null,
      password: null,
      phone: null,
      message: null,
      view: "Login",
      poolData: null,
      domains: {},
      api_url: null
    };
  }

  setState(state) {
    window.localStorage.setItem('state', JSON.stringify(state));
    super.setState(state);
  }

  componentDidMount() {
    const response = this.getConfig();
    response.then(data => {
      const { domains, cognitoConfig, invokeUrl } = data.data;
      this.setState({
        ...this.state,
        poolData: cognitoConfig.poolData,
        domains: domains,
        api_url: invokeUrl
      });
      UserPool = new CognitoUserPool(cognitoConfig.poolData);
    });
  }

  componentDidUpdate(prevProps, prevState) {
    if (
      this.state.expires < (Date.now() / 1000) &&
      this.state.view !== "Login" &&
      this.state.userName !== null &&
      this.state.password !== null
    ) {
      this.setState({
        ...this.state,
        view: "Login",
        userName: null,
        password: null
      });
    }
  }

  getConfig = async () => {
    const response = await axios.get('/config.js');
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
            message: "Your registration has been submitted.",
            view: "Login"
          });
        } else {
          this.setState({
            ...this.state,
            message: err,
            view: "SignUp"
          });
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
          message: null,
          loggedIn: true,
          token: data.getIdToken().getJwtToken(),
          expires: new Date(Math.floor(Date.now() / 1000) + data.expiresIn),
          view: "Request"
        });
      },
      onFailure: data => {
        this.setState({
          ...this.state,
          message: "Login failed",
          loggedIn: false,
          token: null,
          view: "Login"
        });
      }
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
      case "Request":
        return (
          <Request
            token={this.state.token}
            userName={this.state.userName}
            domains={this.state.domains}
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
      case "List":
        return (
          <List
            token={this.state.token}
            api_url={this.state.api_url}
            userName={this.state.userName}
          />
        );
      case "Logout":
        this.setState({...this.state, loggedIn: false, token: null});
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
        />
        <Message message={this.state.message} />
        <div className="content">
          {this.renderContent()}
        </div>
      </div>
    );
  }

}

export default App;
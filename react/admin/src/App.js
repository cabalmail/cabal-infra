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
// import PoolData from './PoolData';
let UserPool = null;

class App extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      loggedIn: false,
      token: null,
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

  componentDidMount() {
    const data = this.getConfig();
    const { domains, cognitoConfig, invokeUrl } = JSON.parse(data);
    this.setState({
      poolData: cognitoConfig.poolData,
      domains: domains,
      api_url: invokeUrl
    });
    UserPool = new CognitoUserPool(cognitoConfig.poolData);
    console.log("UserPool");
  }

  getConfig() {
    axios.get('/config.js').then(response => {
      return response.data;
    }).catch( (err) => {
      if (err.response) {
        console.log("Error in response while retrieving configuration", err.response);
      } else if (err.request) {
        console.log("Error with request while retrieving configuration", err.request);
      } else {
        console.log("Unknown error retrieving configuration", err);
      }
    });
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
            message: "Your registration has been submitted.",
            view: "Login"
          });
        } else {
          this.setState({
            message: err,
            view: "SignUp"
          });
        }
      }
    );
  }

  doLogin = e => {
    e.preventDefault();
    console.log("Pool", UserPool)
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
          message: null,
          loggedIn: true,
          token: data.getIdToken().getJwtToken(),
          view: "Request"
        });
      },
      onFailure: data => {
        this.setState({
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
    this.setState({[e.target.name]: e.target.value});
  }

  updateView = e => {
    e.preventDefault();
    this.setState({view: e.target.name});
  }

  renderContent() {
    switch (this.state.view) {
      case "Request":
        return (
          <Request
            token={this.state.token}
            userName={this.state.userName}
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
            userName={this.state.userName}
          />
        );
      case "Logout":
        this.setState({loggedIn: false, token: null});
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
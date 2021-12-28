import React from 'react';
import {
  CognitoUser,
  CognitoUserPool,
  CognitoUserAttribute,
  AuthenticationDetails
} from 'amazon-cognito-identity-js';
import Request from './Request.js';
import List from './List.js';
import SignUp from './SignUp.js';
import Login from './Login.js';
import Message from './Message.js';
import Nav from './Nav.js';
import PoolData from './PoolData.js';
const UserPool = new CognitoUserPool(PoolData);

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
      view: "Login"
    };
  }

  componentDidMount() {
    const currentUser = UserPool.getCurrentUser();
    if (currentUser) {
      this.setState({loggedIn: true});
    } else {
      this.setState({loggedIn: false, token: null, userName: null, view: "Login"})
    }
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
        console.log(data);
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
        return <Request />;
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
        return <List />;
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
      <div className="App">
        <div className={this.state.view}>
          <Nav onClick={this.updateView} user={this.state.userName} />
          <Message message={this.state.message} />
          {this.renderContent()}
        </div>
      </div>
    );
  }

}

export default App;
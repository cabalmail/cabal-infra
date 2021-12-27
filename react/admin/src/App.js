import React from 'react';
import {
  CognitoUser,
  CognitoUserPool,
  AuthenticationDetails
} from 'amazon-cognito-identity-js';
import Request from './Request.js';
import List from './List.js';
import SignUp from './SignUp.js';
import Login from './Login.js';
import Message from './Message.js';
import PoolData from './PoolData.js';
const UserPool = new CognitoUserPool(PoolData);

class App extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      loggedIn: false,
      user: null,
      userName: null,
      password: null,
      message: null,
      view: "Login"
    };
  }

  componentDidMount() {
    const currentUser = UserPool.getCurrentUser();
    if (currentUser) {
      this.setState({loggedIn: true, user: currentUser});
    } else {
      this.setState({loggedIn: false, user: null, view: "Login"})
    }
  }

  doLogin(e) {
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
          user: data,
          view: "Request"
        });
      },
      onFailure: data => {
        this.setState({
          message: "Login failed",
          user: null,
          view: "Login"
        });
      }
    });
  }

  doUsernameChange(e) {
    e.preventDefault();
    this.setState({userName: e.target.value});
  }

  doPasswordChange(e) {
    e.preventDefault();
    this.setState({password: e.target.value});
  }

  renderContent() {
    switch (this.state.view) {
      case "Request":
        return <Request />;
      case "SignUp":
        return <SignUp />;
      case "List":
        return <List />;
      case "Login":
      default:
        return (
          <Login
            onSubmit={this.doLogin}
            onUsernameChange={this.doUsernameChange}
            onPasswordChange={this.doPasswordChange}
            username={this.state.userName}
            password={this.state.password}
          />
        );
    };
  }

  render() {
    return (
      <div className="App">
        <Message message={this.state.message} />
        {this.renderContent()}
      </div>
    );
  }

}

export default App;
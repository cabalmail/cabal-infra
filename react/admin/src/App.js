import React from 'react';
import { CognitoUserPool } from 'amazon-cognito-identity-js';
import Request from './Request.js';
import List from './List.js';
import SignUp from './SignUp.js';
import Login from './Login.js';
import PoolData from './PoolData.js';
const UserPool = new CognitoUserPool(PoolData);

class App extends React.Component {

  constructor(props) {
    super(props);
    this.state = {
      loggedIn: false,
      user: null,
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
    console.log(e);
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
        return <Login onSubmit={this.doLogin} />;
    };
  }

  render() {
    return (
      <div className="App">
        {this.renderContent()}
      </div>
    );
  }

}

export default App;
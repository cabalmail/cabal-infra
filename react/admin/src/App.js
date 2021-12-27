import React from 'react';
import { CognitoUserPool } from 'amazon-cognito-identity-js';
import Request from './Request.js';
import List from './List.js';
import SignUp from './SignUp.js';
import Login from './Login.js';
import PoolData from './PoolData.js';
const userPool = new CognitoUserPool.CognitoUserPool(PoolData);

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
    const currentUser = userPool.getCurrentUser();
    if (currentUser) {
      this.setState({loggedIn: true, user: currentUser});
    }
  }

  renderContent() {
    switch (this.state.view) {
      case "Request":
        return <Request />;
        break;
      case "SignUp":
        return <SignUp />;
        break;
      case "List":
        return <List />;
        break;
      case "Login":
      default:
        return <Login />;
      };
    alert("Spilled through");
    return <Login />;
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
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
      case "Login":
        return <Login />;
      case "Request":
        return <Request />;
      case "SignUp":
        return <SignUp />;
      case "List":
        return <List />;
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
import React from 'react';
// import AmazonCognitoIdentity from 'amazon-cognito-identity-js';
import Request from './Request.js';
import List from './List.js';
import SignUp from './SignUp.js';
import Login from './Login.js';

function App() {
  return (
    <div className="App">
      <Request />
      <List />
      <SignUp />
      <Login />
    </div>
  );
}

export default App;

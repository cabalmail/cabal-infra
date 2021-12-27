import React from 'react';
// import AmazonCognitoIdentity from 'amazon-cognito-identity-js';
import Request from './Request.js';
import List from './List.js';
import SignUp from './SignUp.js';
import Login from './Login.js';
import PoolData from './PoolData.js';

function App() {
  return (
    <div className="App">
      <Request />
      <List />
      <SignUp />
      <Login client_id={PoolData.ClientId} pool_id={PoolData.UserPoolId} />
    </div>
  );
}

export default App;
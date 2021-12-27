import React from 'react';

class Login extends React.Component {
  render() {
    return (
      <div className="login">
        <form className="login" onSubmit={this.props.onSubmit}>
          <input type="text" className="login username" id="username" name="username" />
          <input type="password" className="login password" id="password" name="password" />
        </form>
      </div>
    );
  }
}

export default Login;
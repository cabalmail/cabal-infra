import React from 'react';

class Login extends React.Component {
  render() {
    return (
      <div className="login">
        <form className="login" onSubmit={this.props.onSubmit}>
          <input type="text" className="login username" id="username" name="username" onChange={this.props.onUsernameChange} />
          <input type="password" className="login password" id="password" name="password" onChange={this.props.onPasswordChange} />
          <button type="submit">Login</button>
        </form>
      </div>
    );
  }
}

export default Login;
import React from 'react';

/**
 * Renders login form
 */

class Login extends React.Component {
  render() {
    return (
      <div className="login">
        <form className="login" onSubmit={this.props.onSubmit}>
          <label htmlFor="userName">User Name</label>
          <input
            type="text"
            className="login username"
            id="userName"
            name="userName"
            onChange={this.props.onUsernameChange}
            value={this.props.username}
          />
          <label htmlFor="password">Password</label>
          <input
            type="password"
            className="login password"
            id="password"
            name="password"
            onChange={this.props.onPasswordChange}
            value={this.props.password}
          />
          <button type="submit" className="default">Login</button>
        </form>
      </div>
    );
  }
}

export default Login;
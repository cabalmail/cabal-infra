import React from 'react';

/**
 * Renders a sign up form.
 */

class SignUp extends React.Component {
  render() {
    return (
      <div className="sign-up">
        <form className="login" onSubmit={this.props.onSubmit}>
          <label for="userName">User Name</label>
          <input
            type="text"
            className="login username"
            id="userName"
            name="userName"
            onChange={this.props.onUsernameChange}
            value={this.props.username}
          />
          <label for="phone">Phone</label>
          <input
            type="text"
            className="login phone"
            id="phone"
            name="phone"
            placeholder="+12125555555"
            onChange={this.props.onPhoneChange}
            value={this.props.phone}
          />
          <label for="password">Password</label>
          <input
            type="password"
            className="login password"
            id="password"
            name="password"
            onChange={this.props.onPasswordChange}
            value={this.props.password}
          />
          <button type="submit" className="default">Signup</button>
        </form>
      </div>
    );
  }
}

export default SignUp;
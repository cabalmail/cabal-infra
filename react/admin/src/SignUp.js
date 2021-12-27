import React from 'react';

class SignUp extends React.Component {
  render() {
    return (
      <div className="sign-up">
        <form className="login" onSubmit={this.props.onSubmit}>
          <input
            type="text"
            className="login username"
            id="username"
            name="username"
            onChange={this.props.onUsernameChange}
            value={this.props.username}
          />
          <input
            type="text"
            className="login phone"
            id="phone"
            name="phone"
            onChange={this.props.onPhoneChange}
            value={this.props.phone}
          />
          <input
            type="password"
            className="login password"
            id="password"
            name="password"
            onChange={this.props.onPasswordChange}
            value={this.props.password}
          />
          <button type="submit">Signup</button>
        </form>
      </div>
    );
  }
}

export default SignUp;
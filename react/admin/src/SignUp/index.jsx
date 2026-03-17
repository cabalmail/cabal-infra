import './SignUp.css';

function SignUp({ onSubmit, onUsernameChange, onPasswordChange, onPhoneChange, username, password, phone }) {
  return (
    <div className="sign-up">
      <form className="login" onSubmit={onSubmit}>
        <label htmlFor="userName">User Name</label>
        <input
          type="text"
          className="login username"
          id="userName"
          name="userName"
          onChange={onUsernameChange}
          value={username || ""}
        />
        <label htmlFor="phone">Phone</label>
        <input
          type="text"
          className="login phone"
          id="phone"
          name="phone"
          placeholder="+12125555555"
          onChange={onPhoneChange}
          value={phone || ""}
        />
        <label htmlFor="password">Password</label>
        <input
          type="password"
          className="login password"
          id="password"
          name="password"
          onChange={onPasswordChange}
          value={password || ""}
        />
        <button type="submit" className="default">Signup</button>
      </form>
    </div>
  );
}

export default SignUp;

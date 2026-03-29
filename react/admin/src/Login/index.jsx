import './Login.css';

function Login({ onSubmit, onUsernameChange, onPasswordChange, username, password }) {
  return (
    <div className="login">
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
        <label htmlFor="password">Password</label>
        <input
          type="password"
          className="login password"
          id="password"
          name="password"
          onChange={onPasswordChange}
          value={password || ""}
        />
        <button type="submit" className="default">Login</button>
      </form>
    </div>
  );
}

export default Login;

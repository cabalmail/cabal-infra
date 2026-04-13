import loginStyles from '../Login/Login.module.css';

function ForgotPassword({ onSubmit, onUsernameChange, username, onCancel }) {
  return (
    <div className={loginStyles.login}>
      <form className={loginStyles.login} onSubmit={onSubmit}>
        <p>Enter your username to receive a password reset code via SMS.</p>
        <label htmlFor="userName">User Name</label>
        <input
          type="text"
          className={`${loginStyles.login} ${loginStyles.username}`}
          id="userName"
          name="userName"
          onChange={onUsernameChange}
          value={username || ""}
        />
        <button type="submit" className="default">Send Reset Code</button>
        <a href="#" onClick={onCancel}>Back to login</a>
      </form>
    </div>
  );
}

export default ForgotPassword;

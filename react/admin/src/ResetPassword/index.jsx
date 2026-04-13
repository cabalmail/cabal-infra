import loginStyles from '../Login/Login.module.css';

function ResetPassword({ onSubmit, onCodeChange, onPasswordChange, code, password }) {
  return (
    <div className={loginStyles.login}>
      <form className={loginStyles.login} onSubmit={onSubmit}>
        <p>Enter the code sent to your phone and your new password.</p>
        <label htmlFor="verificationCode">Verification Code</label>
        <input
          type="text"
          className={`${loginStyles.login} ${loginStyles.username}`}
          id="verificationCode"
          name="verificationCode"
          onChange={onCodeChange}
          value={code || ""}
        />
        <label htmlFor="password">New Password</label>
        <input
          type="password"
          className={`${loginStyles.login} ${loginStyles.password}`}
          id="password"
          name="password"
          onChange={onPasswordChange}
          value={password || ""}
        />
        <button type="submit" className="default">Reset Password</button>
      </form>
    </div>
  );
}

export default ResetPassword;

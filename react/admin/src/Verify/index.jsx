import loginStyles from '../Login/Login.module.css';

function Verify({ onSubmit, onCodeChange, code }) {
  return (
    <div className={loginStyles.login}>
      <form className={loginStyles.login} onSubmit={onSubmit}>
        <p>A verification code has been sent to your phone. Enter it below to complete registration.</p>
        <label htmlFor="verificationCode">Verification Code</label>
        <input
          type="text"
          className={`${loginStyles.login} ${loginStyles.username}`}
          id="verificationCode"
          name="verificationCode"
          onChange={onCodeChange}
          value={code || ""}
        />
        <button type="submit" className="default">Verify</button>
      </form>
    </div>
  );
}

export default Verify;

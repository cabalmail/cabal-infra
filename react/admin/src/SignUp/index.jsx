import styles from './SignUp.module.css';
import loginStyles from '../Login/Login.module.css';

function SignUp({ onSubmit, onUsernameChange, onPasswordChange, onPhoneChange, username, password, phone }) {
  return (
    <div className={styles.signUp}>
      <form className={loginStyles.login} onSubmit={onSubmit}>
        <label htmlFor="userName">User Name</label>
        <input
          type="text"
          className={`${loginStyles.login} ${loginStyles.username}`}
          id="userName"
          name="userName"
          onChange={onUsernameChange}
          value={username || ""}
        />
        <label htmlFor="phone">Phone</label>
        <input
          type="text"
          className={`${loginStyles.login} ${loginStyles.username}`}
          id="phone"
          name="phone"
          placeholder="+12125555555"
          onChange={onPhoneChange}
          value={phone || ""}
        />
        <label htmlFor="password">Password</label>
        <input
          type="password"
          className={`${loginStyles.login} ${loginStyles.password}`}
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

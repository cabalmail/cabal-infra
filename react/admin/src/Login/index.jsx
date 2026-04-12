import styles from './Login.module.css';

function Login({ onSubmit, onUsernameChange, onPasswordChange, username, password }) {
  return (
    <div className={styles.login}>
      <form className={styles.login} onSubmit={onSubmit}>
        <label htmlFor="userName">User Name</label>
        <input
          type="text"
          className={`${styles.login} ${styles.username}`}
          id="userName"
          name="userName"
          onChange={onUsernameChange}
          value={username || ""}
        />
        <label htmlFor="password">Password</label>
        <input
          type="password"
          className={`${styles.login} ${styles.password}`}
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

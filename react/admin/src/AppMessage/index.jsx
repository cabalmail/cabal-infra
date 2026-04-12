import styles from './AppMessage.module.css';

function AppMessage({ message, hide, error }) {
  const visibility = hide ? styles.hidden : styles.visible;
  const level = error ? styles.error : styles.info;
  return (
    <div className={`${styles.appMessage} ${visibility} ${level}`}>{message}</div>
  );
}

export default AppMessage;

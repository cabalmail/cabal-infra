import './AppMessage.css';

function AppMessage({ message, hide, error }) {
  const visibility = hide ? "hidden" : "visible";
  const level = error ? "error" : "info";
  return (
    <div className={`app-message ${visibility} ${level}`}>{message}</div>
  );
}

export default AppMessage;

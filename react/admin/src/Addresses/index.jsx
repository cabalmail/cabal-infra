import React, { useState } from 'react';
import List from './List';
import Request from './Request';
import Admin from './Admin';
import './Addresses.css'

function Addresses({ token, domains, api_url, setMessage, host, isAdmin }) {
  const [showRequest, setShowRequest] = useState(false);
  const [trigger, setTrigger] = useState("");
  const [adminView, setAdminView] = useState(false);

  const toggleRequest = () => {
    setShowRequest(prev => !prev);
  };

  const regenerateList = (address) => {
    setTrigger(address);
    setShowRequest(false);
  };

  if (isAdmin && adminView) {
    return (
      <>
        <button
          onClick={() => setAdminView(false)}
          className="toggleRequest"
        >My Addresses</button>
        <hr />
        <Admin domains={domains} setMessage={setMessage} />
      </>
    );
  }

  return (
    <>
      <button
        onClick={toggleRequest}
        className="toggleRequest"
      >New Address {showRequest ? "▼" : "▶︎"}</button>
      {isAdmin && (
        <button
          onClick={() => setAdminView(true)}
          className="toggleRequest"
        >All Addresses (admin)</button>
      )}
      <Request
        token={token}
        domains={domains}
        api_url={api_url}
        setMessage={setMessage}
        showRequest={showRequest}
        host={host}
        callback={regenerateList}
      />
      <hr />
      <List
        token={token}
        domains={domains}
        api_url={api_url}
        setMessage={setMessage}
        host={host}
        regenerate={trigger}
      />
    </>
  );
}

export default Addresses;

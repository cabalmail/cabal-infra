import React, { useState } from 'react';
import List from './List';
import Request from './Request';
import './Addresses.css'

function Addresses({ token, domains, api_url, setMessage, host }) {
  const [showRequest, setShowRequest] = useState(false);
  const [trigger, setTrigger] = useState("");

  const toggleRequest = () => {
    setShowRequest(prev => !prev);
  };

  const regenerateList = (address) => {
    setTrigger(address);
    setShowRequest(false);
  };

  return (
    <>
      <button
        onClick={toggleRequest}
        className="toggleRequest"
      >New Address {showRequest ? "▼" : "▶︎"}</button>
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

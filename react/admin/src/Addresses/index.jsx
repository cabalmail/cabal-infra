import React, { useState } from 'react';
import List from './List';
import Request from './Request';
import Admin from './Admin';
import './Addresses.css'

function Addresses({ token, domains, api_url, setMessage, host, isAdmin }) {
  const [showRequest, setShowRequest] = useState(false);
  const [trigger, setTrigger] = useState("");
  const [tab, setTab] = useState('mine'); // 'mine' | 'all'

  const toggleRequest = () => {
    setShowRequest(prev => !prev);
  };

  const regenerateList = (address) => {
    setTrigger(address);
    setShowRequest(false);
  };

  const tabs = isAdmin ? (
    <div className="address-tabs">
      <button
        className={`address-tab${tab === 'mine' ? ' active' : ''}`}
        onClick={() => setTab('mine')}
      >My Addresses</button>
      <button
        className={`address-tab${tab === 'all' ? ' active' : ''}`}
        onClick={() => setTab('all')}
      >All Addresses (admin)</button>
    </div>
  ) : null;

  if (isAdmin && tab === 'all') {
    return (
      <>
        {tabs}
        <Admin domains={domains} setMessage={setMessage} />
      </>
    );
  }

  return (
    <>
      {tabs}
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

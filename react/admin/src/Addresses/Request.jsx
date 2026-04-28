import React, { useState, useMemo } from 'react';
import useApi from '../hooks/useApi';
import './Request.css';

function Request({ domains, showRequest, callback, setMessage }) {
  const api = useApi();
  const [username, setUsername] = useState('');
  const [subdomain, setSubdomain] = useState('');
  const [domain, setDomain] = useState('');
  const [comment, setComment] = useState('');

  // Derive address from parts instead of storing in state
  const address = useMemo(() => {
    if (username && subdomain && domain) {
      return `${username}@${subdomain}.${domain}`;
    }
    return '';
  }, [username, subdomain, domain]);

  const randomString = (length, pool1, pool2, pool3) => {
    let string = '';
    const pool1Size = pool1.length;
    const pool2Size = pool2.length;
    const pool3Size = pool3.length;
    for (let i = 0; i < length; i++) {
      switch (i) {
        case 0:
          string += pool1.charAt(Math.floor(Math.random() * pool1Size));
          break;
        case (length - 1):
          string += pool3.charAt(Math.floor(Math.random() * pool3Size));
          break;
        default:
          string += pool2.charAt(Math.floor(Math.random() * pool2Size));
      }
    }
    return string;
  };

  const generateRandom = (e) => {
    e.preventDefault();
    const domainLength = domains.length;
    const alphanum = 'abcdefghijklmnopqrstuvwxyz1234567890';
    setUsername(randomString(8, alphanum, alphanum + '._-', alphanum));
    setSubdomain(randomString(8, alphanum, alphanum + '-', alphanum));
    setDomain(domains[Math.floor(Math.random() * domainLength)].domain);
  };

  const doInputChange = (e) => {
    e.preventDefault();
    const { name, value } = e.target;
    switch (name) {
      case 'username': setUsername(value); break;
      case 'subdomain': setSubdomain(value); break;
      case 'domain': setDomain(value); break;
      case 'comment': setComment(value); break;
      default: break;
    }
  };

  const handleSubmit = (e) => {
    e.preventDefault();
    const requestButton = e.target;
    requestButton.classList.add('sending');
    const submitUsername = username;
    const submitSubdomain = subdomain;
    const submitDomain = domain;
    const submitComment = comment;
    const submitAddress = submitUsername + '@' + submitSubdomain + '.' + submitDomain;
    setUsername("");
    setSubdomain("");
    setDomain("");
    setComment("");
    api.newAddress(
      submitUsername, submitSubdomain, submitDomain, submitComment, submitAddress
    ).then(data => {
      requestButton.classList.remove('sending');
      setMessage(`Successfully requested ${data.data.address}.`, false);
      callback(data.data.address);
    });
  };

  const doClear = (e) => {
    e.preventDefault();
    setUsername("");
    setSubdomain("");
    setDomain("");
    setComment("");
  };

  const getOptions = () => {
    return domains.map(d => (
      <option value={d.domain} key={d.domain}>{d.domain}</option>
    ));
  };

  return (
    <div className={`request ${showRequest ? "requestVisible" : "requestHidden"}`}>
      <fieldset className="request__group request__address">
        <legend className="request__legend">Address</legend>
        <input
          type="text"
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="none"
          value={username}
          onChange={doInputChange}
          id="username"
          name="username"
          placeholder="username"
          className="request__input request__input--username"
        />
        <span className="request__sep" aria-hidden="true">@</span>
        <input
          type="text"
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="none"
          value={subdomain}
          onChange={doInputChange}
          id="subdomain"
          name="subdomain"
          placeholder="subdomain"
          className="request__input request__input--subdomain"
        />
        <span className="request__sep" aria-hidden="true">.</span>
        <select
          name="domain"
          value={domain}
          onChange={doInputChange}
          className="request__select"
        >
          <option value="">Select a domain</option>
          {getOptions()}
        </select>
      </fieldset>
      <fieldset className="request__group request__comment">
        <legend className="request__legend">Comment</legend>
        <input
          type="text"
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="none"
          value={comment}
          onChange={doInputChange}
          id="comment"
          name="comment"
          placeholder="optional note"
          className="request__input request__input--comment"
        />
      </fieldset>
      <fieldset className="request__group request__buttons">
        <button
          type="button"
          className="request__submit"
          onClick={handleSubmit}
        >
          Request {address}
        </button>
        <button
          type="button"
          className="request__secondary"
          onClick={generateRandom}
        >Random</button>
        <button
          type="button"
          className="request__secondary"
          onClick={doClear}
        >Clear</button>
      </fieldset>
    </div>
  );
}

export default Request;

import React, { useState, useCallback } from 'react';
import './Email.css';
import Messages from './Messages';
import MessageOverlay from './MessageOverlay';
import ComposeOverlay from './ComposeOverlay';
import Folders from '../Folders';
import Addresses from '../Addresses';
import { useAuth } from '../contexts/AuthContext';
import { useAppMessage } from '../contexts/AppMessageContext';

const EMPTY_ENVELOPE = {
  from: [],
  to: [],
  subject: ""
};

function prepBody(body, envelope) {
  let sanitizedBody = body;
  let previousBody;
  do {
    previousBody = sanitizedBody;
    sanitizedBody = sanitizedBody
      .replace(/<!--[\s\S]*?-->/gm, "")
      .replace(/&lt;!--[\s\S]*?--&gt;/gm, "");
  } while (sanitizedBody !== previousBody);

  return '<div><p>&#160;</p></div><div><hr /></div>' +
    `<div style="font-weight: bold;">From: ${envelope.from[0]}</div>` +
    `<div style="font-weight: bold;">To: ${envelope.to.join("; ")}</div>` +
    `<div style="font-weight: bold;">Date: ${envelope.date}</div>` +
    `<div style="font-weight: bold;">Subject: ${envelope.subject}</div><div><p>&#160;</p></div>` +
    sanitizedBody.replace(/[\s\S]*<body>/m, "").replace(/<\/body>[\s\S]*/m, "");
}

let composeIdSeq = 0;

function Email({
  filter, setFilter,
  sortKey, setSortKey,
  sortDir, setSortDir,
  bulkMode, setBulkMode,
  selected, setSelected,
  readerFormat, setReaderFormat,
  composeFromAddress, setComposeFromAddress,
}) {
  const { token, api_url, host, domains, smtp_host } = useAuth();
  const { setMessage } = useAppMessage();

  const [folder, setFolder] = useState("INBOX");
  const [addressFilter, setAddressFilter] = useState(null);
  const [overlayVisible, setOverlayVisible] = useState(false);
  const [envelope, setEnvelope] = useState({});
  const [flags, setFlags] = useState([]);
  // §4e: multiple compose windows coexist. Each entry carries its own
  // composeState so windows don't share recipients / subject / body.
  const [composeWindows, setComposeWindows] = useState([]);

  const selectFolder = useCallback((f) => {
    setFolder(f);
    setAddressFilter(null);
  }, []);

  const selectAddress = useCallback((address) => {
    setAddressFilter(address);
  }, []);

  const showOverlay = useCallback((env) => {
    setEnvelope(env);
    setFlags(env.flags);
    setOverlayVisible(true);
  }, []);

  const hideOverlay = useCallback(() => {
    setOverlayVisible(false);
  }, []);

  const closeCompose = useCallback((id) => {
    setComposeWindows(prev => prev.filter(w => w.id !== id));
  }, []);

  const openCompose = useCallback((composeState) => {
    // eslint-disable-next-line no-plusplus
    const id = ++composeIdSeq;
    setComposeWindows(prev => [...prev, { id, ...composeState }]);
  }, []);

  const newEmail = useCallback(() => {
    openCompose({
      new_envelope: EMPTY_ENVELOPE,
      subject: "",
      recipient: "",
      body: "",
      type: "new",
      other_headers: {
        in_reply_to: [],
        references: [],
        message_id: []
      }
    });
  }, [openCompose]);

  const launchComposer = useCallback((recipient, body, env, other_headers, type) => {
    const prefix = type === "forward" ? "Fwd: " : "Re: ";
    const subject = prefix + env.subject.replace(/^(re:?\s|fwd?:?\s)?/i, "");
    const extended_body = prepBody(body, env);
    openCompose({
      new_envelope: env,
      subject: subject,
      recipient: recipient,
      body: extended_body,
      type: type,
      other_headers: other_headers
    });
  }, [openCompose]);

  const reply = useCallback((recipient, body, env, other_headers) => {
    launchComposer(recipient, body, env, other_headers, "reply");
  }, [launchComposer]);

  const replyAll = useCallback((recipient, body, env, other_headers) => {
    launchComposer(recipient, body, env, other_headers, "replyAll");
  }, [launchComposer]);

  const forward = useCallback((recipient, body, env, other_headers) => {
    launchComposer(recipient, body, env, other_headers, "forward");
  }, [launchComposer]);

  return (
    <div className="email">
      <aside className="email__rail" aria-label="Folders and addresses">
        <Folders
          folder={folder}
          setFolder={selectFolder}
          setMessage={setMessage}
          onNewMessage={newEmail}
        />
        <Addresses
          domains={domains}
          setMessage={setMessage}
          selectedAddress={addressFilter}
          onSelectAddress={selectAddress}
        />
      </aside>
      <div className="email__middle">
        <Messages
          token={token}
          api_url={api_url}
          folder={folder}
          host={host}
          showOverlay={showOverlay}
          setFolder={selectFolder}
          setMessage={setMessage}
          addressFilter={addressFilter}
          filter={filter}
          setFilter={setFilter}
          sortKey={sortKey}
          setSortKey={setSortKey}
          sortDir={sortDir}
          setSortDir={setSortDir}
          bulkMode={bulkMode}
          setBulkMode={setBulkMode}
          selected={selected}
          setSelected={setSelected}
        />
        <MessageOverlay
          token={token}
          api_url={api_url}
          envelope={envelope}
          flags={flags}
          visible={overlayVisible}
          folder={folder}
          host={host}
          hide={hideOverlay}
          updateOverlay={showOverlay}
          setMessage={setMessage}
          reply={reply}
          replyAll={replyAll}
          forward={forward}
          readerFormat={readerFormat}
          setReaderFormat={setReaderFormat}
        />
      </div>
      {composeWindows.length > 0 && (
        <div className="compose-stack" aria-label="Compose windows">
          {composeWindows.map((w, i) => (
            <ComposeOverlay
              key={w.id}
              stackIndex={i}
              smtp_host={smtp_host}
              hide={() => closeCompose(w.id)}
              domains={domains}
              body={w.body}
              recipient={w.recipient}
              envelope={w.new_envelope}
              subject={w.subject}
              type={w.type}
              other_headers={w.other_headers}
              composeFromAddress={composeFromAddress}
              setComposeFromAddress={setComposeFromAddress}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export default Email;

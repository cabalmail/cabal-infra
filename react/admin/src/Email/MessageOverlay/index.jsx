import React, { useState, useEffect, useCallback } from 'react';
import RichMessage from './RichMessage';
import Actions from '../Actions';
import useApi from '../../hooks/useApi';
import { useAppMessage } from '../../contexts/AppMessageContext';
import './MessageOverlay.css';
import { ADDRESS_LIST } from '../../constants';

function MessageOverlay({
  envelope, folder, visible, flags, hide: hideProp,
  updateOverlay, reply: replyProp, replyAll: replyAllProp,
  forward: forwardProp, token, api_url, host
}) {
  const api = useApi();
  const { setMessage } = useAppMessage();

  // Separate state for each independent piece to avoid race conditions
  const [messageRawUrl, setMessageRawUrl] = useState("");
  const [messageBodyPlain, setMessageBodyPlain] = useState("");
  const [messageBodyHtml, setMessageBodyHtml] = useState("");
  const [view, setView] = useState("rich");
  const [attachments, setAttachments] = useState([]);
  const [loading, setLoading] = useState(true);
  const [topState, setTopState] = useState("expanded");
  const [bimiUrl, setBimiUrl] = useState("/mask.png");
  const [recipient, setRecipient] = useState("");
  const [messageId, setMessageId] = useState([]);
  const [inReplyTo, setInReplyTo] = useState([]);
  const [references, setReferences] = useState([]);
  const [addresses, setAddresses] = useState([]);

  // Fetch addresses on mount
  useEffect(() => {
    api.getAddresses().then(data => {
      try {
        localStorage.setItem(ADDRESS_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      setAddresses(data.data.Items);
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Fetch message data when envelope changes
  useEffect(() => {
    if (!envelope.id) return;

    setLoading(true);
    setBimiUrl("/mask.png");

    const seen = envelope.flags.includes("\\Seen");

    api.getMessage(folder, envelope.id, seen).then(data => {
      const newView =
        data.data.message_body_plain.length > data.data.message_body_html
          ? "plain"
          : "rich";
      setMessageRawUrl(data.data.message_raw);
      setMessageBodyPlain(data.data.message_body_plain);
      setMessageBodyHtml(data.data.message_body_html);
      setRecipient(data.data.recipient);
      setMessageId(data.data.message_id);
      setInReplyTo(data.data.in_reply_to);
      setReferences(data.data.references);
      setLoading(false);
      setView(newView);
    }).catch(e => {
      setMessage("Unable to get message.", true);
      console.log(e);
    });

    api.getAttachments(folder, envelope.id, seen).then(data => {
      setAttachments(data.data.attachments);
    }).catch(e => {
      setMessage("Unable to get list of attachments.", true);
      console.log(e);
    });

    api.getBimiUrl(envelope.from[0]).then(data => {
      setBimiUrl(data.data.url);
    }).catch(e => {
      console.log(e);
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [envelope.id]);

  const hide = useCallback((e) => {
    e.preventDefault();
    setTopState("expanded");
    hideProp();
  }, [hideProp]);

  const downloadAttachment = useCallback((e) => {
    e.preventDefault();
    const id = parseInt(e.target.dataset.id);
    const a = attachments.find(att => att.id === id);
    api.getAttachment(
      a, folder, envelope.id, envelope.flags.includes("\\Seen")
    ).then((data) => {
      window.open(data.data.url);
    }).catch(() => {
      setMessage("Unable to download attachment.", true);
    });
  }, [attachments, folder, envelope, api, setMessage]);

  const callback = useCallback(() => {
    api.getEnvelopes(folder, [envelope.id]).then(data => {
      updateOverlay(data.data.envelopes[envelope.id]);
    });
  }, [api, folder, envelope.id, updateOverlay]);

  const catchback = useCallback((err) => {
    setMessage("Unable to set flag on message.", true);
    console.log("Unable to set flag on message.");
    console.log(err);
  }, [setMessage]);

  const createPayload = useCallback(() => {
    return [
      recipient,
      messageBodyHtml || messageBodyPlain,
      envelope,
      { message_id: messageId, in_reply_to: inReplyTo, references: references }
    ];
  }, [recipient, messageBodyHtml, messageBodyPlain, envelope, messageId, inReplyTo, references]);

  const reply = useCallback(() => {
    const params = createPayload();
    replyProp(params[0], params[1], params[2], params[3]);
  }, [createPayload, replyProp]);

  const replyAll = useCallback(() => {
    const params = createPayload();
    replyAllProp(params[0], params[1], params[2], params[3]);
  }, [createPayload, replyAllProp]);

  const forward = useCallback(() => {
    const params = createPayload();
    forwardProp(params[0], params[1], params[2], params[3]);
  }, [createPayload, forwardProp]);

  const revokeAddress = useCallback((a) => {
    return api.deleteAddress(a.address, a.subdomain, a.tld, a.public_key);
  }, [api]);

  const revoke = useCallback((e) => {
    e.preventDefault();
    const address = e.target.value;
    revokeAddress(addresses.find(a => a.address === address)).then(() => {
      setMessage("Successfully revoked address.", false);
      setAddresses(prev => prev.filter(a => a.address !== address));
    }, reason => {
      setMessage("Request to revoke address failed.", true);
      console.error("Promise rejected", reason);
    });
  }, [addresses, revokeAddress, setMessage]);

  const renderView = () => {
    if (loading) {
      return <div className="message message_loading" />;
    }
    switch (view) {
      case "rich":
        return (
          <RichMessage
            body={messageBodyHtml}
            seen={envelope.flags.includes("\\Seen")}
            id={envelope.id}
            folder={folder}
            host={host}
            token={token}
            api_url={api_url}
            setMessage={setMessage}
          />
        );
      case "plain":
        return <pre className="message message_plain">{messageBodyPlain}</pre>;
      case "raw":
        return <div className="message_raw"><iframe src={messageRawUrl} title="Raw message"></iframe></div>;
      case "attachments": {
        const attachmentList = attachments.map(a => (
          <button
            key={a.id}
            id={`attachment-${a.id}`}
            className="attachment"
            value={a.id}
            onClick={downloadAttachment}
            data-id={a.id}
          >
            <span className="attachment_name" data-id={a.id}>{a.name}</span>
            <span className="attachment_size" data-id={a.id}>{a.size} bytes</span>
            <span className="attachment_type" data-id={a.id}>{a.type}</span>
          </button>
        ));
        return <div className="message message_attachments">{attachmentList}</div>;
      }
      default:
        return <pre className="message message_raw">{""}</pre>;
    }
  };

  const renderHeader = () => {
    const to = envelope.to.length ? (
      <>
        <dt className="collapsable">To</dt>
        <dd className="collapsable">{envelope.to.join("; ")}</dd>
      </>
    ) : (
      <>
        <dt className="collapsable">To</dt>
        <dd className="collapsable">Undisclosed recipients</dd>
      </>
    );
    const cc = envelope.cc.length ? (
      <>
        <dt className="collapsable">CC</dt>
        <dd className="collapsable">{envelope.cc.join("; ")}</dd>
      </>
    ) : "";
    const bcc = (recipient &&
      envelope.to.indexOf(recipient) === -1 &&
      envelope.cc.indexOf(recipient) === -1) ? (
      <>
        <dt className="collapsable bcc">BCC</dt>
        <dd className="collapsable bcc">{recipient}</dd>
      </>
    ) : "";
    const revokeButton = addresses.map(a => a.address).indexOf(recipient) !== -1 ? (
      <dt className="collapsable"><button
        className="revoke collapsable"
        onClick={revoke}
        value={recipient}
        title={`Revoke ${recipient}`}
      >&#128465;&#65039; Revoke {recipient}</button></dt>
    ) : "";
    return (
      <dl>
        <dt className="collapsable">From</dt>
        <dd className="collapsable">{envelope.from.join("; ")}</dd>
        {to}
        {bcc}
        {cc}
        <dt className="collapsable">Received</dt>
        <dd className="collapsable">{envelope.date}</dd>
        <dt className="collapsable">Subject</dt>
        <dd>{envelope.subject}</dd>
        {revokeButton}
      </dl>
    );
  };

  const renderTabBar = () => (
    <div className={`tabBar ${view}`}>
      <button className={`tab ${view === "rich" ? "active" : ""}`}
        onClick={() => setView("rich")} value="rich"
        title="Show the HTML formatted version">Rich Text</button>
      <button className={`tab ${view === "plain" ? "active" : ""}`}
        onClick={() => setView("plain")} value="plain"
        title="Show the plain text version">Plain Text</button>
      <button className={`tab ${view === "attachments" ? "active" : ""}`}
        onClick={() => setView("attachments")} value="attachments"
        title="Show attachments">&#128206;</button>
      <button className={`tab ${view === "raw" ? "active" : ""}`}
        onClick={() => setView("raw")} value="raw"
        title="View the raw message source">&lt;/&gt;</button>
    </div>
  );

  const flagClasses = flags.map(d => d.replace("\\", "")).join(" ");

  if (visible) {
    return (
      <div className="message_overlay">
        <div className={`message_top ${topState} ${flagClasses}`}>
          <button onClick={(e) => { e.preventDefault(); setTopState("collapsed"); }}
            className="overlay_expand_collapse collapse_overlay_top"
            title="Hide message header">&#9650;</button>
          <button onClick={(e) => { e.preventDefault(); setTopState("expanded"); }}
            className="overlay_expand_collapse expand_overlay_top"
            title="Show message header">&#9660;</button>
          <Actions
            token={token}
            api_url={api_url}
            host={host}
            folder={folder}
            selected_messages={[envelope.id]}
            selected="selected "
            order=""
            field="ARRIVAL"
            callback={callback}
            catchback={catchback}
            reply={reply}
            replyAll={replyAll}
            forward={forward}
            setMessage={setMessage}
          />
          <button onClick={hide} className="close_overlay"
            title="Close message">&#10060;</button>
          {renderHeader()}
          {renderTabBar()}
          <div className="bimi">
            <img src={bimiUrl} alt="" />
          </div>
        </div>
        {renderView()}
      </div>
    );
  }
  return <div className="message_overlay overlay_hidden"></div>;
}

export default MessageOverlay;

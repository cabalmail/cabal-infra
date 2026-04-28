import React, { useState, useCallback, useEffect } from 'react';
import './Email.css';
import Messages from './Messages';
import MessageOverlay from './MessageOverlay';
import ComposeOverlay from './ComposeOverlay';
import Folders from '../Folders';
import AddressesRail from '../Addresses/Rail';
import useMediaQuery from '../hooks/useMediaQuery';
import useSplit from './useSplit';
import { useAuth } from '../contexts/AuthContext';
import { useAppMessage } from '../contexts/AppMessageContext';

const EMPTY_ENVELOPE = {
  from: [],
  to: [],
  subject: ""
};

function Splitter({ split, orientation, ariaLabel }) {
  const className = orientation === 'horizontal'
    ? 'email__rail-splitter'
    : 'email__col-splitter';
  const gripClassName = orientation === 'horizontal'
    ? 'email__rail-splitter-grip'
    : 'email__col-splitter-grip';
  return (
    <div
      className={className}
      role="separator"
      aria-orientation={orientation}
      aria-valuemin={split.min}
      aria-valuemax={split.max}
      aria-valuenow={Math.round(split.pct)}
      aria-label={ariaLabel}
      tabIndex={0}
      onPointerDown={split.onPointerDown}
      onKeyDown={split.onKeyDown}
      onDoubleClick={split.reset}
      title="Drag to resize (double-click to reset)"
    >
      <span className={gripClassName} aria-hidden="true" />
    </div>
  );
}

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
  shortcutHandlersRef,
}) {
  const { token, api_url, host, domains, smtp_host } = useAuth();
  const { setMessage } = useAppMessage();

  // Phase 8: responsive layout breakpoints.
  //   phone   — <768px  : one pane; Folders as drawer; Reader/Compose as sheets
  //   tablet  — ≥768px  : two panes (Messages + Reader); Folders as drawer
  //   desktop — ≥1200px : three panes, Folders in-flow
  const isDesktop = useMediaQuery('(min-width: 1200px)');
  const isTabletUp = useMediaQuery('(min-width: 768px)');
  const layout = isDesktop ? 'desktop' : isTabletUp ? 'tablet' : 'phone';

  const railSplit = useSplit({
    storageKey: 'cabal-rail-split',
    defaultPct: 50, min: 15, max: 85, axis: 'y',
  });
  const colRailSplit = useSplit({
    storageKey: 'cabal-col-rail-split',
    defaultPct: 22, min: 15, max: 30, axis: 'x',
  });
  const colMiddleSplit = useSplit({
    storageKey: 'cabal-col-middle-split',
    defaultPct: 46, min: 25, max: 65, axis: 'x',
  });

  const [folder, setFolder] = useState("INBOX");
  const [addressFilter, setAddressFilter] = useState(null);
  const [overlayVisible, setOverlayVisible] = useState(false);
  const [envelope, setEnvelope] = useState({});
  const [flags, setFlags] = useState([]);
  const [drawerOpen, setDrawerOpen] = useState(false);
  // §4e: multiple compose windows coexist. Each entry carries its own
  // composeState so windows don't share recipients / subject / body.
  const [composeWindows, setComposeWindows] = useState([]);

  const closeDrawer = useCallback(() => setDrawerOpen(false), []);
  const openDrawer = useCallback(() => setDrawerOpen(true), []);

  // Close drawer when layout reaches desktop — rail becomes in-flow and the
  // drawer UI would otherwise stay stuck open underneath.
  useEffect(() => {
    if (isDesktop && drawerOpen) setDrawerOpen(false);
  }, [isDesktop, drawerOpen]);

  // The global Nav (rendered outside this tree) owns the hamburger button;
  // it dispatches `cabal:toggle-nav-drawer` when tapped. Listen here so the
  // button can drive the drawer without lifting state to App.jsx.
  useEffect(() => {
    const toggle = () => setDrawerOpen((v) => !v);
    window.addEventListener('cabal:toggle-nav-drawer', toggle);
    return () => window.removeEventListener('cabal:toggle-nav-drawer', toggle);
  }, []);

  const selectFolder = useCallback((f) => {
    setFolder(f);
    setAddressFilter(null);
    setDrawerOpen(false);
    setOverlayVisible(false);
  }, []);

  const selectAddress = useCallback((address) => {
    setAddressFilter(address);
    setOverlayVisible(false);
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

  // Register keyboard-shortcut handlers with App-level hook.
  useEffect(() => {
    if (!shortcutHandlersRef) return undefined;
    const ref = shortcutHandlersRef;
    ref.current = {
      ...ref.current,
      onCompose:    () => newEmail(),
      onGoToFolder: (f) => selectFolder(f),
      onEscape:     () => {
        if (overlayVisible) { hideOverlay(); return; }
        if (composeWindows.length > 0) { closeCompose(composeWindows[composeWindows.length - 1].id); }
      },
    };
    return () => {
      if (ref.current) {
        delete ref.current.onCompose;
        delete ref.current.onGoToFolder;
        delete ref.current.onEscape;
      }
    };
  }, [shortcutHandlersRef, newEmail, selectFolder, overlayVisible, hideOverlay, composeWindows, closeCompose]);

  // On phone the reader takes over the whole middle pane — hide the msglist
  // body while the reader is open so we don't see both stacked.
  const middleMode = layout === 'phone' && overlayVisible ? 'reader' : 'list';

  return (
    <div
      className="email"
      data-layout={layout}
      data-middle={middleMode}
      ref={colRailSplit.containerRef}
    >
      {layout === 'desktop' ? (
        <>
          <aside
            className="email__rail"
            aria-label="Folders and addresses"
            ref={railSplit.containerRef}
            style={{ flexBasis: `${colRailSplit.pct}%` }}
          >
            <div
              className="email__rail-pane"
              style={{ flexBasis: `${railSplit.pct}%` }}
            >
              <Folders
                folder={folder}
                setFolder={selectFolder}
                setMessage={setMessage}
                onNewMessage={newEmail}
              />
            </div>
            <Splitter
              split={railSplit}
              orientation="horizontal"
              ariaLabel="Resize folder list"
            />
            <div
              className="email__rail-pane"
              style={{ flexBasis: `${100 - railSplit.pct}%` }}
            >
              <AddressesRail
                domains={domains}
                setMessage={setMessage}
                selectedAddress={addressFilter}
                onSelectAddress={selectAddress}
              />
            </div>
          </aside>
          <Splitter
            split={colRailSplit}
            orientation="vertical"
            ariaLabel="Resize folders sidebar"
          />
        </>
      ) : (
        drawerOpen && (
          <>
            <div
              className="email__scrim"
              role="presentation"
              onClick={closeDrawer}
            />
            <aside
              className="email__rail email__rail--drawer"
              aria-label="Folders and addresses"
              ref={railSplit.containerRef}
            >
              <div
                className="email__rail-pane"
                style={{ flexBasis: `${railSplit.pct}%` }}
              >
                <Folders
                  folder={folder}
                  setFolder={selectFolder}
                  setMessage={setMessage}
                  onNewMessage={() => { setDrawerOpen(false); newEmail(); }}
                  asDrawer
                  onClose={closeDrawer}
                />
              </div>
              <Splitter
                split={railSplit}
                orientation="horizontal"
                ariaLabel="Resize folder list"
              />
              <div
                className="email__rail-pane"
                style={{ flexBasis: `${100 - railSplit.pct}%` }}
              >
                <AddressesRail
                  domains={domains}
                  setMessage={setMessage}
                  selectedAddress={addressFilter}
                  onSelectAddress={(a) => { setAddressFilter(a); setDrawerOpen(false); }}
                />
              </div>
            </aside>
          </>
        )
      )}

      <div
        className="email__middle"
        ref={colMiddleSplit.containerRef}
        style={layout !== 'phone'
          ? { '--msglist-width': `${colMiddleSplit.pct}%` }
          : undefined}
      >
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
          layout={layout}
          onOpenDrawer={openDrawer}
          onCompose={newEmail}
        />
        {layout !== 'phone' && (
          <Splitter
            split={colMiddleSplit}
            orientation="vertical"
            ariaLabel="Resize message list"
          />
        )}
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
          layout={layout}
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
              layout={layout}
            />
          ))}
        </div>
      )}
    </div>
  );
}

export default Email;

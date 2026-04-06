import React, { useState, useCallback, useEffect } from 'react';
import Observer from './Observer';
import { SwipeableList, Type } from 'react-swipeable-list';
import 'react-swipeable-list/dist/styles.css';
import Envelope from './Envelope';
import useApi from '../../hooks/useApi';
import { PAGE_SIZE } from '../../constants';
import './Envelopes.css';

function Envelopes({
  message_ids, folder, selected_messages, showOverlay,
  handleCheck: handleCheckProp, handleSelect: handleSelectProp,
  markUnread: markUnreadProp, markRead: markReadProp, archive: archiveProp
}) {
  const api = useApi();

  const [envelopes, setEnvelopes] = useState({});
  const [pages, setPages] = useState([]);

  const loadPages = useCallback((pageNums) => {
    setPages(currentPages => {
      setEnvelopes(prev => {
        let merged = { ...prev };
        for (const p of pageNums) {
          if (currentPages[p]) {
            merged = { ...merged, ...currentPages[p] };
          }
        }
        return merged;
      });
      return currentPages;
    });
  }, []);

  // Fetch envelopes when message_ids change
  useEffect(() => {
    let cancelled = false;
    const numIds = message_ids.length;

    for (let i = 0; i < numIds; i += PAGE_SIZE) {
      const ids = message_ids.slice(i, i + PAGE_SIZE);
      const page = Math.floor(i / PAGE_SIZE);

      api.getEnvelopes(folder, ids).then(data => {
        if (cancelled) return;

        // Use functional update to avoid race condition
        setPages(prev => {
          const next = prev.slice();
          next[page] = data.data.envelopes;
          return next;
        });

        // Auto-load first few pages into the visible envelopes
        if (page < 4) {
          setEnvelopes(prev => ({
            ...prev,
            ...data.data.envelopes
          }));
        }
      }).catch(e => {
        console.log(e);
      });
    }

    return () => {
      cancelled = true;
    };
  }, [api, folder, message_ids]);

  const handleClick = useCallback((envelope, id) => {
    showOverlay(envelope);
    handleSelectProp(id);
  }, [showOverlay, handleSelectProp]);

  const handleCheck = useCallback((id, checked) => {
    handleCheckProp(id, checked);
  }, [handleCheckProp]);

  const markRead = useCallback((id) => {
    setEnvelopes(prev => {
      const next = JSON.parse(JSON.stringify(prev));
      if (next[id.toString()]) {
        next[id.toString()].flags.push("\\Seen");
      }
      return next;
    });
    markReadProp(id);
  }, [markReadProp]);

  const markUnread = useCallback((id) => {
    setEnvelopes(prev => {
      const next = JSON.parse(JSON.stringify(prev));
      const envelope = next[id.toString()];
      if (envelope) {
        envelope.flags.splice(envelope.flags.indexOf("\\Seen"), 1);
      }
      return next;
    });
    markUnreadProp(id);
  }, [markUnreadProp]);

  const archive = useCallback((id) => {
    archiveProp(id);
  }, [archiveProp]);

  let i = 0;
  const message_list = message_ids.filter(k => {
    return envelopes.hasOwnProperty(k.toString());
  }).map(k => {
    return envelopes[k.toString()];
  }).map(e => {
    let first_of_page = false;
    let observer = null;
    const page = Math.floor(i / PAGE_SIZE);
    if (i % PAGE_SIZE === 0) {
      first_of_page = true;
      observer = (
        <Observer
          pageLoader={loadPages}
          page={page + 2}
          key={page + 2}
        />
      );
    }
    i++;
    return (
      <Envelope
        handleClick={handleClick}
        handleCheck={handleCheck}
        archive={archive}
        markRead={markRead}
        markUnread={markUnread}
        envelope={e}
        subject={e.subject}
        priority={e.priority}
        date={e.date}
        from={e.from}
        to={e.to}
        cc={e.cc}
        flags={e.flags}
        struct={e.struct}
        is_checked={selected_messages.includes(parseInt(e.id))}
        dom_id={e.id}
        page={page}
        first_of_page={first_of_page}
        observer={observer}
        key={e.id}
      />
    );
  });

  return (
    <SwipeableList
      fullSwipe={true}
      type={Type.IOS}
      className="message-list"
    >
      {message_list}
    </SwipeableList>
  );
}

export default Envelopes;

import React, { useEffect, useMemo, useState } from 'react';
import { initialsFor, domainFor } from '../../utils/formatDate';
import { peekBimi } from '../../utils/bimiCache';

/* Resolve a sender domain's BIMI logo URL through the shared session cache.
   Returns undefined while loading, null when there is no logo, or the URL.
   `getBimi` is supplied by the list (it closes over the api client), so the
   row stays decoupled from auth context; without it the avatar just shows
   initials and never fetches. */
function useBimiUrl(domain, getBimi) {
  const [url, setUrl] = useState(() => peekBimi(domain));
  useEffect(() => {
    if (!domain || typeof getBimi !== 'function') {
      setUrl(null);
      return undefined;
    }
    const cached = peekBimi(domain);
    if (cached !== undefined) {
      setUrl(cached);
      return undefined;
    }
    let active = true;
    getBimi(domain).then((resolvedUrl) => {
      if (active) setUrl(resolvedUrl || null);
    });
    return () => {
      active = false;
    };
  }, [domain, getBimi]);
  return url;
}

/* Leading sender avatar for a message-list row: the sender domain's BIMI
   logo when one resolves, otherwise an initials plate. The initials are the
   always-present base layer, so the slot never reflows when a logo loads
   late. Mirrors the Apple client's AvatarView (minus the Contacts-photo
   tier, which has no web equivalent). */
function BimiAvatar({ from, getBimi }) {
  const domain = useMemo(() => domainFor(from), [from]);
  const initials = useMemo(() => initialsFor(from), [from]);
  const url = useBimiUrl(domain, getBimi);
  const [imgFailed, setImgFailed] = useState(false);

  // A new URL (row recycled to a different sender) gets a fresh chance to load.
  useEffect(() => {
    setImgFailed(false);
  }, [url]);

  const showLogo = Boolean(url) && !imgFailed;
  return (
    <span className="envelope-avatar" aria-hidden="true">
      {showLogo ? (
        <img
          className="envelope-avatar-logo"
          src={url}
          width="24"
          height="24"
          alt=""
          onError={() => setImgFailed(true)}
        />
      ) : (
        <span className="envelope-avatar-initials">{initials}</span>
      )}
    </span>
  );
}

export default BimiAvatar;

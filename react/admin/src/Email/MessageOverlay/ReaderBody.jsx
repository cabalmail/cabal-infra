import React, { useEffect, useMemo, useRef, useState } from 'react';
import useApi from '../../hooks/useApi';

/* =========================================================================
   Reader body — §4d.
   Rich mode: sandboxed srcdoc iframe, height-probed post-load.
   Plain mode: <pre> with white-space: pre-wrap.

   Per Preflight (4), the server returns raw HTML — sanitization happens
   client-side. For Phase 4 the sanitization posture is "render inside a
   sandbox without allow-scripts so the HTML cannot execute JS, navigate
   the top frame, or phone home". `allow-same-origin` is enabled so the
   parent can measure `scrollHeight` to size the iframe to content. A
   deeper sanitization pass and Match-theme injection land in Phase 5.
   ========================================================================= */

const IFRAME_SANDBOX = 'allow-same-origin allow-popups allow-popups-to-escape-sandbox';

function blockTrackingImages(html) {
  // Defuse http(s) <img> srcs so remote images don't load until the user
  // opts in. `cid:` URLs are untouched; they're rewritten with presigned
  // URLs after the message-load phase.
  return html.replace(/(<img\b[^>]*?\bsrc=["'])(https?:)/gi, '$1disabled-$2');
}

function restoreTrackingImages(html) {
  return html.replace(/(<img\b[^>]*?\bsrc=["'])disabled-(https?:)/gi, '$1$2');
}

function ReaderBody({
  format, html, plain, folder, messageId, seen, setMessage,
}) {
  const api = useApi();
  const iframeRef = useRef(null);

  const [imagesLoaded, setImagesLoaded] = useState(false);
  const [iframeHeight, setIframeHeight] = useState(120);

  const hasRemoteImages = useMemo(
    () => /(<img\b[^>]*?\bsrc=["'])https?:/i.test(html || ''),
    [html],
  );

  // Compose the srcdoc. Tracking images are defused unless the user opted
  // in; cid: references are resolved to presigned URLs asynchronously.
  const [resolvedHtml, setResolvedHtml] = useState('');

  useEffect(() => {
    if (format !== 'rich') return undefined;
    let cancelled = false;

    const base = imagesLoaded ? html : blockTrackingImages(html || '');

    const cids = Array.from(
      (base || '').matchAll(/(<img\b[^>]*?\bsrc=["'])cid:([^"']+)(["'])/gi),
    ).map((m) => m[2]);

    if (cids.length === 0) {
      setResolvedHtml(base || '');
      return undefined;
    }

    const uniq = Array.from(new Set(cids));
    Promise.all(
      uniq.map((cid) =>
        api
          .fetchImage(cid, folder, messageId, seen)
          .then((r) => [cid, r.data.url])
          .catch(() => [cid, null]),
      ),
    ).then((pairs) => {
      if (cancelled) return;
      let out = base || '';
      for (const [cid, url] of pairs) {
        if (!url) continue;
        const escaped = cid.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        out = out.replace(
          new RegExp(`(<img\\b[^>]*?\\bsrc=["'])cid:${escaped}(["'])`, 'gi'),
          `$1${url}$2`,
        );
      }
      setResolvedHtml(out);
    }).catch(() => {
      if (setMessage) setMessage('Unable to load inline image.', true);
    });

    return () => { cancelled = true; };
  }, [format, html, imagesLoaded, folder, messageId, seen, api, setMessage]);

  // Height probe on load. The sandbox allows same-origin so we can read
  // scrollHeight directly. Re-probe after late image loads settle.
  useEffect(() => {
    if (format !== 'rich') return undefined;
    const iframe = iframeRef.current;
    if (!iframe) return undefined;

    let raf = 0;
    const measure = () => {
      try {
        const doc = iframe.contentDocument;
        if (!doc) return;
        const h = Math.max(
          doc.documentElement.scrollHeight,
          doc.body ? doc.body.scrollHeight : 0,
        );
        if (h && Math.abs(h - iframeHeight) > 2) setIframeHeight(h);
      } catch {
        /* cross-origin: sandbox didn't get allow-same-origin */
      }
    };

    const onLoad = () => {
      measure();
      // Remeasure after images settle.
      raf = window.setTimeout(measure, 250);
    };
    iframe.addEventListener('load', onLoad);
    return () => {
      iframe.removeEventListener('load', onLoad);
      if (raf) window.clearTimeout(raf);
    };
  }, [format, resolvedHtml, iframeHeight]);

  if (format === 'plain') {
    return (
      <div className="reader-body">
        <pre className="reader-body-plain">{plain || ''}</pre>
      </div>
    );
  }

  return (
    <>
      {hasRemoteImages && !imagesLoaded && (
        <div className="reader-images" role="status">
          <span>Remote images are blocked to protect your privacy.</span>
          <button
            type="button"
            onClick={() => {
              setImagesLoaded(true);
              setResolvedHtml(restoreTrackingImages(resolvedHtml));
            }}
          >
            Load images
          </button>
        </div>
      )}
      <div className="reader-body">
        <iframe
          ref={iframeRef}
          className="reader-body-iframe"
          title="Message body"
          sandbox={IFRAME_SANDBOX}
          srcDoc={resolvedHtml || '<html><body></body></html>'}
          style={{ height: `${iframeHeight}px` }}
        />
      </div>
    </>
  );
}

export default ReaderBody;

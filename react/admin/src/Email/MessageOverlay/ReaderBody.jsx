import React, { useEffect, useMemo, useRef, useState } from 'react';
import useApi from '../../hooks/useApi';

/* =========================================================================
   Reader body — §4d.
   Rich mode: sandboxed srcdoc iframe, height-probed post-load.
   Plain mode: <pre> with white-space: pre-wrap.

   Match theme (Phase 5): when enabled in Rich mode, we inject a <style>
   block into the iframe's <head> that sets body background / color /
   font-family using *resolved literal values* — CSS custom properties do
   not cross the iframe boundary, so we read them from the parent's
   documentElement via getComputedStyle and write them in verbatim.

   Per Preflight (4), the server returns raw HTML — sanitization happens
   client-side. The sandbox denies script execution; `allow-same-origin`
   is retained so the parent can measure scrollHeight.
   ========================================================================= */

const IFRAME_SANDBOX = 'allow-same-origin allow-popups allow-popups-to-escape-sandbox';

/* Tokens we pull from the parent's computed style for Match theme. These
   are the ones we inline — keep the list short so we don't cascade the
   entire design system into sender-written HTML. */
const MATCH_THEME_TOKENS = ['--reader-bg', '--ink', '--font-reader'];

function blockTrackingImages(html) {
  // Defuse http(s) <img> srcs so remote images don't load until the user
  // opts in. `cid:` URLs are untouched; they're rewritten with presigned
  // URLs after the message-load phase.
  return html.replace(/(<img\b[^>]*?\bsrc=["'])(https?:)/gi, '$1disabled-$2');
}

function restoreTrackingImages(html) {
  return html.replace(/(<img\b[^>]*?\bsrc=["'])disabled-(https?:)/gi, '$1$2');
}

function resolveMatchThemeTokens() {
  if (typeof window === 'undefined' || !window.getComputedStyle) return null;
  const cs = window.getComputedStyle(document.documentElement);
  const out = {};
  for (const name of MATCH_THEME_TOKENS) {
    const v = cs.getPropertyValue(name).trim();
    if (v) out[name] = v;
  }
  return out;
}

function buildMatchThemeStyle(tokens) {
  if (!tokens) return '';
  const bg = tokens['--reader-bg'] || 'transparent';
  const ink = tokens['--ink'] || 'inherit';
  const font = tokens['--font-reader'] || 'serif';
  /* The naive background-neutralization pass from the README: any inline
     `background: #fff` or `background-color: #ffffff` gets swapped to the
     reader background token so white islands inside dark mode don't look
     marooned. Production-grade sanitization is flagged in the plan as a
     v1-follow-up. */
  return `
<style data-cabal-match-theme>
  html, body { background: ${bg} !important; color: ${ink} !important; font-family: ${font}; }
  [style*="background: #fff"],
  [style*="background:#fff"],
  [style*="background-color: #fff"],
  [style*="background-color:#fff"],
  [style*="background: #ffffff"],
  [style*="background-color: #ffffff"],
  [style*="background: white"],
  [style*="background-color: white"] {
    background: ${bg} !important;
    background-color: ${bg} !important;
  }
</style>`;
}

/* Prepend the Match theme <style> block to the srcdoc. If the HTML has a
   <head>, slot it in there; otherwise drop it at the start so the
   browser's implicit head-promotion picks it up. */
function injectMatchThemeStyle(html, styleBlock) {
  if (!styleBlock) return html;
  if (!html) return `<html><head>${styleBlock}</head><body></body></html>`;
  if (/<head[^>]*>/i.test(html)) {
    return html.replace(/<head([^>]*)>/i, `<head$1>${styleBlock}`);
  }
  if (/<html[^>]*>/i.test(html)) {
    return html.replace(/<html([^>]*)>/i, `<html$1><head>${styleBlock}</head>`);
  }
  return `${styleBlock}${html}`;
}

function ReaderBody({
  format, html, plain, folder, messageId, seen, setMessage,
  matchTheme = false, themeKey,
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
  // in; cid: references are resolved to presigned URLs asynchronously;
  // the Match-theme style block (if on) is prepended last so its rules
  // win over anything the sender wrote.
  const [resolvedHtml, setResolvedHtml] = useState('');

  useEffect(() => {
    if (format !== 'rich') return undefined;
    let cancelled = false;

    const base = imagesLoaded ? html : blockTrackingImages(html || '');

    const cids = Array.from(
      (base || '').matchAll(/(<img\b[^>]*?\bsrc=["'])cid:([^"']+)(["'])/gi),
    ).map((m) => m[2]);

    const finalize = (htmlStr) => {
      if (cancelled) return;
      const styleBlock = matchTheme
        ? buildMatchThemeStyle(resolveMatchThemeTokens())
        : '';
      setResolvedHtml(injectMatchThemeStyle(htmlStr || '', styleBlock));
    };

    if (cids.length === 0) {
      finalize(base || '');
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
      finalize(out);
    }).catch(() => {
      if (setMessage) setMessage('Unable to load inline image.', true);
    });

    return () => { cancelled = true; };
  }, [format, html, imagesLoaded, folder, messageId, seen, api, setMessage, matchTheme, themeKey]);

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
          data-match-theme={matchTheme ? 'on' : 'off'}
        />
      </div>
    </>
  );
}

export default ReaderBody;

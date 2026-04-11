import React, { useState, useEffect, useRef, useCallback } from 'react';
import useApi from '../../hooks/useApi';
import DOMPurify from 'dompurify';

function RichMessage({ body, seen, id, folder, setMessage }) {
  const api = useApi();
  const messageHtmlRef = useRef(null);

  const disabledBody = body.replace(/src="http/g, 'src="disabled-http');
  const hasRemoteImages = disabledBody !== body;

  const [renderMode, setRenderMode] = useState("normal");
  const [displayBody, setDisplayBody] = useState(disabledBody);
  const [imagesLoaded, setImagesLoaded] = useState(false);

  // Load inline images (cid: protocol) after mount
  useEffect(() => {
    const el = messageHtmlRef.current;
    if (!el) return;
    const imgs = el.getElementsByTagName("img");
    for (let i = 0; i < imgs.length; i++) {
      const results = imgs[i].src.match(/^cid:([^"]*)/);
      if (results !== null) {
        const img = imgs[i];
        api.fetchImage(results[1], folder, id, seen)
          .then(data => { img.src = data.data.url; })
          .catch(() => { setMessage("Unable to load inline image.", true); });
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const loadRemoteImages = useCallback(() => {
    setDisplayBody(body);
    setImagesLoaded(true);
  }, [body]);

  const rotateBackground = useCallback((e) => {
    e.preventDefault();
    setRenderMode(prev => {
      switch (prev) {
        case "normal": return "forced";
        case "forced": return "inverted";
        case "inverted": return "normal";
        default: return "normal";
      }
    });
  }, []);

  return (
    <div className={`message message_html ${renderMode}`}>
      <div className="buttons">
        <button
          className="invert"
          onClick={rotateBackground}
          title="Invert background (useful when the text color is too close to the default background color)"
        >&#9680;</button>
        <button
          className={`load ${hasRemoteImages && !imagesLoaded ? "" : "hidden"}`}
          onClick={loadRemoteImages}
          title="Download remote images (could allow third parties to track your interactions with this message)"
        >&#8681;</button>
      </div>
      <div
        ref={messageHtmlRef}
        id="message_html"
        className={renderMode}
        dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(displayBody) }}
      />
    </div>
  );
}

export default RichMessage;

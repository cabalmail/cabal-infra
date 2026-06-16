import React from 'react';
import { InView } from 'react-intersection-observer';

// Sentinel that calls `onVisible` when it scrolls into view, used to trigger
// the next lazy page of envelopes. Only fires on entering view (not leaving),
// so it can't run the loader twice per pass.
const Observer = ({ onVisible }) => (
  <InView
    onChange={(inView) => { if (inView) onVisible(); }}
    triggerOnce={false}
  >
    {({ ref }) => <div ref={ref} className="envelopes-load-sentinel" aria-hidden="true" />}
  </InView>
);

export default Observer;

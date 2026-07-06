- The unused `dompurify` dependency from the React admin client. It was
  never imported; received email HTML is rendered in a sandboxed iframe with no
  `allow-scripts`, which is what neutralizes scripts. Documentation that
  described a DOMPurify sanitization step (and the long-replaced Draft.js
  editor) is corrected to match.

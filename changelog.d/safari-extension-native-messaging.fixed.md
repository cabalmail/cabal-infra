- Apple: **The built-in Safari extension now takes your server from the
  app.** The extension embedded in the Mac and iOS apps is meant to ask
  the app which Cabalmail server you are signed into, so you never type it
  twice — but its manifest did not request native messaging, and WebKit
  only hands that bridge to an extension that asks for it. The request was
  therefore never made and the popup always showed its "which Cabalmail
  server should this extension use?" form instead. It now asks for the
  permission, so the embedded extension takes the server from the app. The
  separately-installed Safari and Chrome builds are unaffected and still
  ask in the popup.

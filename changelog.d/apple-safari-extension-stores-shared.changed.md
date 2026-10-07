- Apple: **The Safari extension's server and private-link stores move
  into the shared module.** No visible change. The two small stores the
  Safari extension reads, the server the app is signed in to and the
  short-lived private-link rows, were compiled into the extension from
  the app's own source folder by path. They now live in the shared module
  the extensions link, beside the notification hand-off, and a pull
  request that changes the token store now runs the extension's tests.
  Nothing should look or behave differently; anything that does is a bug
  worth reporting.

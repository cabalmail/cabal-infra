- Apple: **Mail rules no longer opens on "Couldn't reach the server."** On
  iPhone the Rules screen is torn down and rebuilt during the navigation
  transition, which cancelled its first fetch; the cancellation was painted as
  a server failure and nothing retried it, so every push after the first one in
  a session needed Retry. A cancelled load now leaves the screen loading and
  the fetch is taken over by the rebuilt screen.

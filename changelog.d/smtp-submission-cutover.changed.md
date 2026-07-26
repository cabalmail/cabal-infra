- **The send Lambda submits mail privately.** Outbound submission from
  /send now dials the smtp-out task directly over its new Cloud Map name
  (TLS on 465, verified against the tier certificate) instead of
  hairpinning through NAT to the public submission listener, with an
  automatic fallback to the public path if the internal name does not
  answer. Public submission (465/587) itself is unchanged and remains
  open to standard mail clients.

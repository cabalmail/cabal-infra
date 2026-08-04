- **A failed send no longer makes the next attempt a silent no-op.** `/send`
  claims a message's Message-Id before handing it to the relay so a retry
  cannot deliver twice, but only released the claim when the SMTP step
  returned an error - not when it raised, which is what a relay refusing
  the connection does. The orphaned claim then matched the client's retry
  and answered it `200 "submitted"` without sending anything until the
  claim expired. The claim is now released on any failure under it, an
  unreachable relay comes back as a named error instead of a bodiless 502,
  and a connection that breaks after the message is accepted keeps the
  claim so the retry still cannot duplicate it.

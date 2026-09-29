- Apple: **Rapid swipe-to-dispose stays on the right row.** Disposing
  message after message from the top of the list, a swipe made while the
  server was still answering the previous one could open its actions on
  the message below the one under your thumb or pointer: the disposed row
  had finished its exit animation but stayed in the list until the server
  replied, so the rows had not really moved up yet. The row now leaves as
  soon as its animation ends, and no row takes a new tap or swipe during
  that animation. A refresh already under way when a message was archived,
  moved or deleted can also no longer bring it back for a moment.

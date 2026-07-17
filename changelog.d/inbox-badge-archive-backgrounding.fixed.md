- Apple: **Icon badge tracks archives immediately.** The badge is now
  updated the moment a message is archived or marked read, rather than
  waiting for the 60-second Inbox poll — which can't run once the app is
  backgrounded, so archiving then backgrounding used to leave the badge
  showing the pre-archive count. Archive also commits in a single API round
  trip (the server marks `\Seen` before moving), so it reliably lands within
  the brief window the app has when it's being backgrounded.

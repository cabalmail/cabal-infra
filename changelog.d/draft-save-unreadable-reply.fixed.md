- Apple: **No duplicate draft when the server's reply is unreadable.**
  `/save_draft` stores the new copy and expunges the one it supersedes
  before it answers, so a 200 whose body cannot be parsed is a save that
  landed. The composer read it as a failure — leaving the window up with
  "Couldn't read the server's reply" over a draft the server had already
  stored — and went on naming the copy that save had replaced, so the next
  save replaced nothing and left two drafts behind. The client now finds the
  copy it wrote by the Message-Id it stamped on it; when it cannot, the save
  is reported as saved with its coordinates unknown rather than as a
  failure, and an open Drafts list is still told which copy went away.

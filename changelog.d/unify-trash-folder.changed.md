- The web client now files deletions in the server's special-use "Trash"
  mailbox, the same folder the Apple clients use, instead of its own
  "Deleted Messages" folder. Deleted mail is no longer indexed for search
  (matching the Apple clients), and `/move_messages` auto-creates "Trash"
  instead of "Deleted Messages", fixing first-delete-to-Trash failures on
  fresh mailboxes. An existing "Deleted Messages" folder is left in place
  as an ordinary folder; it can now be emptied and removed from the web
  folder manager.

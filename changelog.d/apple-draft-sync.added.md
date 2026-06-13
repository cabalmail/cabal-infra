- The Apple clients sync compose drafts across devices through
  `/save_draft`: close-without-send and a 60-second debounce push the
  buffer to the IMAP Drafts folder, each save replaces the previous server
  copy, send discards it, and a new "Edit Draft" action in the Drafts
  folder resumes a draft where another device left off. Local `DraftStore`
  autosave remains the editing buffer and crash-recovery story.

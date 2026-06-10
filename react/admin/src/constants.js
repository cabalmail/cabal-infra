export const ONE_SECOND = 1000;

export const PERMANENT_FOLDERS = [
  "INBOX",
  "Trash",
  "Sent Messages",
  "Drafts",
  "Archive"
];

export const ASC = {
  imap: "",
  css: "ascending",
  description: "Ascending order (smallest/first to largest/last)"
};
export const DESC = {
  imap: "REVERSE ",
  css: "descending",
  description: "Descending order (largest/last to smallest/first)"
};
export const ARRIVAL = {
  imap: "ARRIVAL",
  css: "arrival",
  description: "Date Received"
};
export const DATE = {
  imap: "DATE",
  css: "date",
  description: "Date Sent"
};
export const FROM = {
  imap: "FROM",
  css: "from",
  description: "From address"
};
export const SUBJECT = {
  imap: "SUBJECT",
  css: "subject",
  description: "Subject"
};
export const TO = {
  imap: "TO",
  css: "to",
  description: "Recipient"
};
export const PAGE_SIZE = 30;
export const READ = {
  imap: '\\Seen',
  css: "read",
  description: "Mark read",
  op: "set",
  action: "read",
  icon: "🐵"
};
export const UNREAD = {
  imap: '\\Seen',
  css: "unread",
  description: "Mark unread",
  op: "unset",
  action: "unread",
  icon: "🙈"
};
export const FLAGGED = {
  imap: '\\Flagged',
  css: "flagged",
  description: "Flag",
  op: "set",
  action: "flag",
  icon: "📫"
};
export const UNFLAGGED = {
  imap: '\\Flagged',
  css: "unflagged",
  description: "Unflag",
  op: "unset",
  action: "unflag",
  icon: "📪"
};
export const REPLY = {
  css: "reply",
  description: "Reply",
  icon: "👈"
}
export const REPLYALL = {
  css: "replyall",
  description: "Reply All",
  icon: "👈👈"
}
export const FORWARD = {
  css: "forward",
  description: "Forward",
  icon: "👉"
}
export const FOLDER_LIST = "folder_list";
export const ADDRESS_LIST = "address_list";
export const FOLDER_COLLAPSED_SUB = "folder_collapsed_sub";
export const FOLDER_COLLAPSED_ALL = "folder_collapsed_all";
export const FOLDER_COLLAPSED_PATHS = "folder_collapsed_paths";
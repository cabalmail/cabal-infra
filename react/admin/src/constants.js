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
export const PAGE_SIZE = 50;
export const READ = {
  imap: "\\Seen",
  css: "read",
  description: "Mark read",
  op: "set",
  action: "read",
  icon: "✉️"
};
export const UNREAD = {
  imap: "\\Seen",
  css: "unread",
  description: "Mark unread",
  op: "unset",
  action: "unread",
  icon: "🔵"
};
export const FLAGGED = {
  imap: "\\Flagged",
  css: "flagged",
  description: "Flag",
  op: "set",
  action: "flag",
  icon: "📫"
};
export const UNFLAGGED = {
  imap: "\\Flagged",
  css: "unflagged",
  description: "Unflag",
  op: "unset",
  action: "unflag",
  icon: "📪"
};
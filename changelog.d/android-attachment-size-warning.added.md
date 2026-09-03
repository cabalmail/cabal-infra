- Android: **Warning when attachments get too big.** The composer now shows an advisory line under the attachment
  chips once they total more than 20 MB — "Attachments total 24.0 MB. Many mail servers reject messages over 25 MB;
  delivery may fail." — matching the React and Apple composers. Like both of them it is advisory only and does not
  block the send: the recipient's server may accept more. Previously the first sign of the problem was the server's
  400 at send time, after every attachment had already uploaded.

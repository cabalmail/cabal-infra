- **Mail no longer arrives with an empty body part.** `/send` and
  `/save_draft` sent the text and HTML bodies as `multipart/alternative`
  even when one of them was empty. A reader shows the last part it can
  render, so a message whose HTML body was empty displayed as a blank body
  in any client showing rich content, with the text reachable only as
  plain text. Both parts now go out only when both have content;
  otherwise the message is a single part holding the one that does.

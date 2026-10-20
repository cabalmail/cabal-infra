- Apple: **Rules newer than the app stay readable.** A stored rule whose
  condition field or action this build doesn't know — written by a newer
  client or a newer server — now lists as a read-only row that says what it
  uses, and is saved back to the server unchanged. The rules this build does
  understand stay editable beside it; previously one such rule made the whole
  set fail to decode, so the editor showed only a load error.

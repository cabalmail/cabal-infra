- Apple: **Photo attachments keep their real format.** Pictures attached from
  the photo library on iPhone, iPad and Vision Pro went out announced as
  `image/jpeg` with a `.jpg` name whatever they actually were — the bytes
  were never converted, so a PNG or a camera HEIC arrived intact inside a
  part describing it as something else. Recipients that trust the declared
  type could fail to render it, and "save attachment" wrote a `.jpg` that was
  not a JPEG. The composer now reads the format out of the bytes it is about
  to send.

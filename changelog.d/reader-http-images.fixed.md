- Apple: **Images addressed over plain `http` now load.** A message or
  feed item whose pictures still use `http://` addresses (Electoral Vote's
  do) showed broken boxes even with remote content allowed, because the
  reader refuses insecure loads. The reader now asks for every such
  picture over `https` instead, which is what those publishers serve.

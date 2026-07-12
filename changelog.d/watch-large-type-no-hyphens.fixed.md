- Apple: **No more inserted hyphens in the watch's large-type address view.**
  When a long address wrapped, the layout engine broke it mid-token and
  inserted a soft hyphen — ambiguous, since an address can contain a real
  hyphen. The address now wraps at any character with nothing inserted, so
  every visible character is one the reader should type.

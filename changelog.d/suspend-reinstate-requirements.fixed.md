- **`suspend_address` / `reinstate_address` import failure.** Both new
  Lambdas shipped with an empty `requirements.txt`, so the build bundled
  `helper.py` (whose `imap_session` dependency imports `imapclient`) without
  the pinned third-party packages, and every invocation died with
  `Runtime.ImportModuleError: No module named 'imapclient'`. They now pin
  the same hashed dependency set as the other helper-importing endpoints.

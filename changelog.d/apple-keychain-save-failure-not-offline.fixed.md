- Apple: **A session that can't be saved no longer passes as offline.**
  If the app renewed your session at launch but the device's keychain
  wouldn't save the renewed sign-in, the launch carried on as if offline
  with the old, expired one, and every later request renewed it again. It
  now stops on "Couldn't read or save data on this device." and keeps the
  saved session for the next launch. Other keychain failures also read as
  a problem on the device rather than "The connection failed."

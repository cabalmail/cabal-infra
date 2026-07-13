- Apple: **macOS notifications now show message content.** The Mac
  notification extension could not read the mirrored sign-in token from the
  shared keychain (a macOS/iOS platform difference in group-less keychain
  searches), so every notification fell back to the generic "New mail";
  it now names the shared group explicitly. Mark as Read and Archive from
  a notification also update the open app immediately instead of waiting
  for the next refresh.

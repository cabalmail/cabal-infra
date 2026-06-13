- Lambda dependency installs are now hash-pinned. Every per-function
  `requirements.txt` carries `--hash` constraints for its packages and
  their full transitive tree (imapclient now lists an explicit, pinned
  `six`), and the api/counter build scripts install with
  `pip --require-hashes`. A tampered or mirror-substituted wheel now
  fails the build instead of being bundled into the function zip.

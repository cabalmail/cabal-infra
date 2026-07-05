- Removed three more unused runtime dependencies from the admin web
  client (`web-vitals`, `@tiptap/extension-color`,
  `@tiptap/extension-text-style`); none were imported by application
  code or present in the shipped bundle, so the generated third-party
  notices are unaffected.

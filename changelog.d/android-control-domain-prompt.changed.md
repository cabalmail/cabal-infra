- Android: **Sign-in asks for the server.** The sign-in screen now takes the
  control domain alongside the username and password, the same as the Apple
  client, and remembers it per install so it is prefilled next time. Nothing
  environment-specific is baked into the build any more: one build works
  against any Cabalmail deployment, and Settings shows the server under
  Account. Existing installs whose build carried a domain keep their session;
  any other install is asked to sign in once, entering the server.

- **Sign-up detection on passwordless first-step pages.** A sign-up flow that
  asks only for an email address on its first step carries none of the
  password-shaped signals the detector leans on, so pages like WordPress's
  `/start/account/user` stayed in the ambiguous band and never offered an
  address on their own. The detector now also reads the legal agreement such a
  page asks you to make — "by continuing you agree to our Terms of Service",
  next to the form rather than only inside a checkbox — which is what account
  creation involves and what signing in, subscribing to a newsletter, or
  sending a contact form does not. Both halves are required, so a page footer
  that merely links the terms still counts for nothing.

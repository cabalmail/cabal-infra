- **Mail API checks the account name before it connects.** The API now
  refuses, before connecting to the mail server, an account name that is
  not all lowercase or that contains `*`. Every name the sign-up screen
  allows passes.
